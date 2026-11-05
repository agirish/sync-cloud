import Testing
import Foundation
@testable import SyncCloud

/// What the window has to keep for the workspaces it destroys.
///
/// `verticalSplit` is a `switch` over `contentLayout`, each arm a separate SwiftUI identity, so a
/// workspace switch tears the outgoing view tree down and anything in its own `@State` goes with
/// it. The few things a reader set are held by `ContentView` instead, mounted once for the
/// window's life. These scans hold the call sites, since nothing rendered would notice a host
/// going back to keeping nothing.
@Suite struct WorkspaceSessionHoistTests {

    /// `@State`, not `@StateObject`: the window must own the lens session, so it survives the
    /// switches that destroy `LensWorkspaceView`, without observing it. `@StateObject` would
    /// re-render the whole window's body on every keystroke in Organize's search field and every
    /// duplicate resolve. `@State` on a reference type stores without subscribing.
    @Test func theWindowOwnsTheLensSessionWithoutObservingIt() throws {
        let source = try macAppSources()
        // Internal rather than private since the result message's "Save as Rule…" hands it to its
        // own observing button (`ContentView+ResultMessage.swift`); still `@State`, still unobserved.
        #expect(source.contains("@State var lensSession = LensWorkspaceSession()"),
                "the window's lens session is missing or is a @StateObject — a @StateObject here subscribes the whole window to Organize's typing")
        #expect(source.contains("session: lensSession"),
                "the lens is no longer handed the window's session, so every narrowing resets on the next switch")
    }

    /// A caret anchor is dropped wherever the text it was measured against is. The places that
    /// discard the buffer (Discard in the divergence alert, reloading a changed file) drop the undo
    /// stack, and a caret offset is the same claim in smaller form: clamped, it is still the wrong
    /// place, and a file recreated at that path would inherit it.
    ///
    /// Counted against the undo store's own sites, so the rule stays "wherever the stack goes, the
    /// caret goes". The `#require` is the positive control against an empty search.
    @Test func aDiscardedOrReloadedBufferDropsItsCaretAnchor() throws {
        let source = try macAppSources()
        let undoDrops = source.components(separatedBy: "editorUndoStore.forget(path)").count - 1
        try #require(undoDrops > 0,
                     "the undo store is never dropped by path any more — the caret's rule is anchored to that one and has drifted")
        let caretDrops = source.components(separatedBy: "caretAnchors.forget(path)").count - 1
        #expect(caretDrops == undoDrops,
                "the caret anchor is dropped at \(caretDrops) of the \(undoDrops) sites that drop the undo stack — a buffer thrown away leaves its caret behind")
    }

    /// The pane's open folders are held per side by the window. Browse's pane, the lens rail and
    /// Compare's left pane are all the left pane (one tree, one path, one provider), so a folder
    /// opened in one is open in the others. Two sets because Compare shows both at once.
    @Test func theWindowHoldsEachPanesOpenFolders() throws {
        let source = try macAppSources()
        #expect(source.contains("@State var leftTreeExpanded: Set<String> = []"))
        #expect(source.contains("@State var rightTreeExpanded: Set<String> = []"))
        #expect(source.contains("hostExpanded: pane.isLeft ? $leftTreeExpanded : $rightTreeExpanded"),
                "the pane no longer receives the window's expansion set — its open folders die with the workspace again")
    }
}
