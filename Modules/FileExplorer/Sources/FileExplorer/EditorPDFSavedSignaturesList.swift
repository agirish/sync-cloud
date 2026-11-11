import AppKit
import Design
import Events
import PDFToolkitCore
import SwiftUI

/// **Settings ▸ Edit ▸ PDF ▸ Saved signatures** (TE332): the signatures and initials Fill & Sign
/// keeps on this Mac, each with Delete…. Drawn here, not in Settings, because the store and the
/// pictures are this module's and Settings can't see it; the app hands it to Settings as a view.
///
/// Delete… asks first, in Fill & Sign's own words (decision BE), since nothing brings one back.
/// A store of its own over the same defaults, so a deletion here reaches an open PDF's palette
/// through the store's defaults observer, and one made there shows here.
public struct EditorPDFSavedSignaturesList: View {
    @StateObject private var store: EditorPDFSignatureStore
    /// The question; a test passes its own answer, since a modal alert blocks a test's main thread.
    private let confirm: @MainActor (EditorPDFSignature, String) -> Bool

    public init(defaults: UserDefaults = .standard) {
        self.init(store: EditorPDFSignatureStore(defaults: defaults))
    }

    init(store: @autoclosure @escaping () -> EditorPDFSignatureStore,
         confirm: @escaping @MainActor (EditorPDFSignature, String) -> Bool = { signature, name in
        EditorPDFFillSign.deleteSavedAlert(signature, name: name).runModal() == .alertSecondButtonReturn
    }) {
        _store = StateObject(wrappedValue: store())
        self.confirm = confirm
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.saved.isEmpty {
                Text("None yet. Fill & Sign’s Signature and Initials tools add them.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.saved) { signature in
                HStack(spacing: 8) {
                    picture(signature)
                    Spacer(minLength: 8)
                    Button("Delete…") { Self.deleteIfConfirmed(signature, from: store, confirm: confirm) }
                        .controlSize(.small)
                        .accessibilityLabel("Delete \(signature.spokenName(among: store.saved))")
                        .help("Deletes this saved \(signature.kind == .signature ? "signature" : "set of initials"). What you’ve already placed on a page stays. Asks first.")
                }
            }
        }
    }

    /// Delete…, as one step: ask, by the name the menus use, and only then delete.
    /// - Returns: Whether it was deleted.
    @discardableResult
    static func deleteIfConfirmed(_ signature: EditorPDFSignature, from store: EditorPDFSignatureStore,
                                  confirm: (EditorPDFSignature, String) -> Bool) -> Bool {
        guard confirm(signature, signature.spokenName(among: store.saved)) else { return false }
        store.delete(signature.id)
        // Settings' change line (C11), in its words; never the typed words, which may be a name.
        Logger.shared.info("Settings: Saved signatures: a \(signature.kind == .signature ? "signature" : "set of initials") deleted (Settings window)")
        return true
    }

    /// A typed one in its script face, a drawn one as its picture, each under its kind.
    @ViewBuilder
    private func picture(_ signature: EditorPDFSignature) -> some View {
        HStack(spacing: 8) {
            switch signature.look {
            case .typed(let words):
                Text(words)
                    .font(Font(PDFToolkit.font(size: signature.face == .zapfino ? 13 : 18, script: true,
                                               font: signature.face.toolkit)))
                    .lineLimit(1)
            case .drawn:
                if let image = EditorPDFSignatureMenu.image(signature, height: 26) {
                    Image(nsImage: image)
                        .accessibilityLabel(signature.spokenName(among: store.saved))
                }
            }
            Text(signature.kind.title)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
