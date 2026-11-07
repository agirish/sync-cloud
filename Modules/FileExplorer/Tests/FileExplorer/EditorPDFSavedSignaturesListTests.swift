import Testing
import Foundation
@testable import FileExplorer
import EventsTestSupport

/// Settings ▸ Edit ▸ PDF ▸ Saved signatures: Delete… asks first, by the name the menus give it, and
/// deletes only the one asked about. Over a real store, read back from its defaults.
@MainActor
@Suite struct EditorPDFSavedSignaturesListTests {

    private func store(_ name: String) -> (EditorPDFSignatureStore, ScratchDefaults, [EditorPDFSignature]) {
        let defaults = ScratchDefaults(name)
        let store = EditorPDFSignatureStore(defaults: defaults)
        let typed = EditorPDFSignature(kind: .signature, look: .typed("Ada Quill"))
        let drawn = EditorPDFSignature(kind: .initials, look: .drawn(strokes: [[.zero, CGPoint(x: 1, y: 1)]], aspect: 2))
        store.add(typed)
        store.add(drawn)
        return (store, defaults, [typed, drawn])
    }

    @Test func decliningDeleteKeepsTheSignature() {
        let (store, defaults, saved) = store("SavedSignaturesList-decline")
        var asked = 0

        let deleted = EditorPDFSavedSignaturesList.deleteIfConfirmed(saved[0], from: store) { _, _ in asked += 1; return false }

        #expect(!deleted)
        #expect(asked == 1, "Delete… didn't ask")
        #expect(EditorPDFSignatureStore(defaults: defaults).saved.count == 2, "a declined Delete… deleted")
    }

    @Test func confirmingDeleteRemovesOnlyThatOneAfterAskingByName() {
        let (store, defaults, saved) = store("SavedSignaturesList-confirm")
        var askedName = ""
        var countWhenAsked = -1

        let deleted = EditorPDFSavedSignaturesList.deleteIfConfirmed(saved[1], from: store) { _, name in
            askedName = name
            countWhenAsked = EditorPDFSignatureStore(defaults: defaults).saved.count
            return true
        }

        #expect(deleted)
        #expect(askedName == "Drawn initials 1, medium pen", "asked by a name the menus don't use")
        #expect(countWhenAsked == 2, "it was deleted before the question")
        #expect(EditorPDFSignatureStore(defaults: defaults).saved.map(\.id) == [saved[0].id])
    }
}
