import Testing
import Foundation
@testable import SyncCloud

/// **What the window has to keep for the workspaces it destroys.**
///
/// `verticalSplit` lays the window out as a `switch` over `contentLayout`, and each arm is a
/// separate SwiftUI identity — so moving between Browse, Compare, Organize and Edit tears the
/// outgoing workspace's view tree down and builds the incoming one from nothing. Anything a
/// workspace kept in its own `@State` went with it.
///
/// The fix is not to stop that happening. It is to hold the handful of things a reader actually set
/// somewhere that outlives it, and `ContentView` is the only view in the app that does — it is
/// mounted once for the window's life. These scans hold the call sites, because nothing rendered
/// notices a host quietly going back to keeping nothing.
@MainActor
@Suite struct WorkspaceSessionHoistTests {

    /// **`@State`, not `@StateObject`, and the difference is a window-wide re-render.**
    ///
    /// The window must OWN the lens session — so it survives the switches that destroy
    /// `LensWorkspaceView` — without OBSERVING it. `@StateObject` here would subscribe this
    /// four-thousand-line body to every keystroke in Organize's search field and every duplicate
    /// resolve. `@State` on a reference type stores without subscribing; the lens observes it and
    /// re-renders alone.
    @Test func theWindowOwnsTheLensSessionWithoutObservingIt() throws {
        let source = try macAppSources()
        #expect(source.contains("@State private var lensSession = LensWorkspaceSession()"),
                "the window's lens session is missing or is a @StateObject — a @StateObject here subscribes the whole window to Organize's typing")
        #expect(source.contains("session: lensSession"),
                "the lens is no longer handed the window's session, so every narrowing resets on the next switch")
    }

    /// **A caret anchor is dropped wherever the text it was measured against is.**
    ///
    /// Both places that discard the buffer — answering the divergence alert with Discard, and
    /// reloading a changed file from disk — already drop the undo stack, because registrations made
    /// against text that is going away name places in a document that will not exist. A caret
    /// offset is the same claim in smaller form: clamping stops it crashing, it does not stop it
    /// being the wrong place, and a file recreated at a path somebody once read would inherit a
    /// caret from a file it has nothing to do with.
    ///
    /// Counted against the undo store's own sites rather than asserted as a number, so the rule
    /// stays "wherever the stack goes, the caret goes" and a third such site cannot be added with
    /// only half of it. The `#require` is the positive control: with the undo call gone this fails
    /// saying so rather than passing on an empty search.
    @Test func aDiscardedOrReloadedBufferDropsItsCaretAnchor() throws {
        let source = try macAppSources()
        let undoDrops = source.components(separatedBy: "editorUndoStore.forget(path)").count - 1
        try #require(undoDrops > 0,
                     "the undo store is never dropped by path any more — the caret's rule is anchored to that one and has drifted")
        let caretDrops = source.components(separatedBy: "caretAnchors.forget(path)").count - 1
        #expect(caretDrops == undoDrops,
                "the caret anchor is dropped at \(caretDrops) of the \(undoDrops) sites that drop the undo stack — a buffer thrown away leaves its caret behind")
    }

    /// The pane's open folders are held per SIDE by the window.
    ///
    /// Per side rather than per workspace because Browse's pane, the lens rail and Compare's left
    /// pane are all the left pane — one tree, one path, one provider — so a folder opened in one
    /// should be open in the others. Two sets because Compare shows both at once.
    @Test func theWindowHoldsEachPanesOpenFolders() throws {
        let source = try macAppSources()
        #expect(source.contains("@State var leftTreeExpanded: Set<String> = []"))
        #expect(source.contains("@State var rightTreeExpanded: Set<String> = []"))
        #expect(source.contains("hostExpanded: pane.isLeft ? $leftTreeExpanded : $rightTreeExpanded"),
                "the pane no longer receives the window's expansion set — its open folders die with the workspace again")
    }
}
