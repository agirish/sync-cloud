import Testing
import Foundation
@testable import FileExplorer

/// **The ordering `ContentView.loadIntoEditor` keeps between the document and its undo stack — the
/// one property standing between the editor and an `NSRangeException`.**
///
/// `EditorUndoStoreTests` covers the store's own rules: one stack per path, a stack refused when
/// its fingerprint no longer fits. What none of them covers is the SEQUENCE those calls are made
/// in relative to the buffer being replaced, and that is the half a crash comes out of.
/// `NSTextView` registers undo by character RANGE in the buffer the edit was made against;
/// `PlainTextEditor.updateNSView` hands the view a `(text, undoManager)` pair read from one render
/// pass. If a pass ever sees the NEW document's text beside the OLD document's manager, ⌘Z
/// replays one file's ranges into another — splicing where they land, or throwing and taking every
/// unsaved buffer in the window with it.
///
/// Today that cannot happen, and for a reason nothing asserts: the whole load is one synchronous
/// main-actor block, and SwiftUI cannot render inside one. **These tests exist so that the reason
/// survives the block being broken up.** Moving the read off the main actor puts a suspension
/// point into the middle of this sequence, and only one placement of it is safe.
@MainActor
@Suite struct EditorLoadOrderingTests {

    // MARK: The sequence under test

    /// Where a suspension point sits in the load.
    ///
    /// Named rather than a Bool because the whole finding is that these two are not
    /// interchangeable: the first is the placement an asynchronous read may use, and the second is
    /// the one that opens the crash window.
    enum Gap {
        /// The read has not landed yet: the buffer and the stack are both still the OUTGOING
        /// document's. This is where an `await` on the file read belongs.
        case beforeTheDocumentIsReplaced
        /// The buffer now holds the INCOMING document and the stack has not been swapped for it.
        case betweenTheDocumentAndTheUndoStack
        case none
    }

    /// `ContentView.loadIntoEditor`'s sequence, with a hook where a suspension would go.
    ///
    /// Kept in the test rather than extracted from the app target on purpose: the app target is
    /// not in this package, so what is pinned here is the SHAPE any implementation must have. The
    /// three calls, in this order, are the whole of it.
    private func load(_ path: String, into document: EditorDocument, store: EditorUndoStore,
                      gap: Gap = .none, observe: () -> Void = {}) {
        store.remember(text: document.text)
        store.forgetMissingFiles()
        if case .beforeTheDocumentIsReplaced = gap { observe() }
        EditorFileStore.load(path: path, into: document)
        if case .betweenTheDocumentAndTheUndoStack = gap { observe() }
        store.activate(path: document.path, text: document.text)
    }

    /// What `PlainTextEditor.updateNSView` reads in one render pass.
    private struct RenderedPair {
        var text: String
        var manager: UndoManager
    }
    private func render(_ document: EditorDocument, _ store: EditorUndoStore) -> RenderedPair {
        RenderedPair(text: document.text, manager: store.current)
    }

    private func fixture(_ files: [String: String]) throws -> [String: String] {
        let folder = NSTemporaryDirectory() + "load-order-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        var paths: [String: String] = [:]
        for (name, body) in files {
            let path = (folder as NSString).appendingPathComponent(name)
            try body.write(toFile: path, atomically: true, encoding: .utf8)
            paths[name] = path
        }
        return paths
    }

    // MARK: The invariant

    /// **Every pair a render pass can see names ONE document.**
    ///
    /// The observation is taken from inside the gap, which is the only place the pair can be
    /// caught disagreeing — after the load returns, the two are trivially in step. With the
    /// suspension where it belongs, the observer sees the outgoing document whole: its text beside
    /// its own stack.
    @Test func theBufferAndTheUndoStackNeverNameTwoDocuments() throws {
        let paths = try fixture(["a.md": "alpha", "b.md": "bravo"])
        let document = EditorDocument()
        let store = EditorUndoStore()

        load(paths["a.md"]!, into: document, store: store)
        let stackForA = store.current
        #expect(document.text == "alpha")

        var seen: RenderedPair?
        load(paths["b.md"]!, into: document, store: store,
             gap: .beforeTheDocumentIsReplaced) { seen = render(document, store) }

        let pair = try #require(seen)
        // The pair the observer caught is a's text with a's stack — not b's text with a's stack,
        // which is the crash.
        #expect(pair.text == "alpha", "the buffer was replaced before the read had landed")
        #expect(pair.manager === stackForA,
                "the undo stack was swapped away from the document still on screen")
        // And once the load has finished, the pair has moved to b together.
        #expect(document.text == "bravo")
        #expect(store.current !== stackForA, "b was handed a's undo stack")
    }

    /// **`remember` takes the text it is PARTING FROM, and `activate` the text that ARRIVED.**
    ///
    /// The store fingerprints whatever it is handed, so both calls are satisfied by the wrong
    /// string and neither fails at the time. What fails is the return trip: file a's stack against
    /// b's text and coming back to a hands back a stack whose registrations name a buffer this is
    /// not.
    @Test func aRoundTripReturnsTheStackTheDocumentWasLeftWith() throws {
        let paths = try fixture(["a.md": "alpha", "b.md": "bravo"])
        let document = EditorDocument()
        let store = EditorUndoStore()

        load(paths["a.md"]!, into: document, store: store)
        let stackForA = store.current
        load(paths["b.md"]!, into: document, store: store)
        #expect(store.current !== stackForA)
        load(paths["a.md"]!, into: document, store: store)
        #expect(store.current === stackForA,
                "a's history was lost across a round trip — its stack was filed against the wrong text")
    }

    /// **The positive control for the test above**: the store really does refuse a stack whose
    /// buffer moved, so `aRoundTripReturnsTheStackTheDocumentWasLeftWith` is asserting that the
    /// sequence keeps them in step rather than that the store never refuses anything.
    @Test func aStackIsStillRefusedWhenTheFileChangedWhileItWasAway() throws {
        let paths = try fixture(["a.md": "alpha", "b.md": "bravo"])
        let document = EditorDocument()
        let store = EditorUndoStore()

        load(paths["a.md"]!, into: document, store: store)
        let stackForA = store.current
        load(paths["b.md"]!, into: document, store: store)
        try "alpha, edited elsewhere".write(toFile: paths["a.md"]!, atomically: true, encoding: .utf8)
        load(paths["a.md"]!, into: document, store: store)
        #expect(store.current !== stackForA,
                "a stack was replayed into a buffer that changed while it was away")
    }

    /// **A refused file replaces the buffer too**, so it must take the stack with it. `open`'s
    /// `.refused` arm empties the text and clears the stamp; leaving the previous document's
    /// manager current would leave ⌘Z live over an empty buffer with another file's ranges in it.
    @Test func aRefusedOpenAlsoMovesTheUndoStack() throws {
        let paths = try fixture(["a.md": "alpha"])
        let document = EditorDocument()
        let store = EditorUndoStore()

        load(paths["a.md"]!, into: document, store: store)
        let stackForA = store.current
        load((paths["a.md"]! as NSString).deletingLastPathComponent + "/not-here.md",
             into: document, store: store)
        #expect(document.text.isEmpty)
        #expect(store.current !== stackForA,
                "a refused open left the previous document's undo stack live over an empty buffer")
    }
}
