import Design
import SwiftUI
import Sync

/// What a card needs to let the user type a home in full: check a path, suggest folders, file.
struct FilingPathEditorHooks {
    /// The current home, relative to the tree, to start from.
    let initial: String
    let validate: (String) -> Result<FilingDestination, FileSyncManager.TypedPathRefusal>
    let complete: (String) -> [String]
    /// "Create and File", "Create and File 9".
    let commitTitle: String
    let onCommit: (FilingDestination) -> Void
}

/// The popover behind "Edit Path…": a full path anywhere in the tree (decision 7), with the folders
/// you already have suggested as you type, and the levels it would create named before anything is.
struct FilingPathEditor: View {
    let hooks: FilingPathEditorHooks
    let onDone: () -> Void
    @State private var text: String = ""
    /// Checked and completed once per edit, not per render: both touch the disk or the folder list.
    @State private var checked: Result<FilingDestination, FileSyncManager.TypedPathRefusal> = .failure(.empty)
    @State private var suggestions: [String] = []
    /// Return and the button can both land in one run loop; the second must not file twice.
    @State private var committed = false
    @FocusState private var focused: Bool
    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Path").scaledFont(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            TextField("Folder/Subfolder", text: $text)
                .textFieldStyle(.roundedBorder)
                .scaledFont(.system(size: 12, design: .monospaced))
                .focused($focused)
                .onSubmit(commit)
                .accessibilityLabel("Folder path")
            switch checked {
            case .success(let dest):
                Text(FilingPathEditorText.preview(dest))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(dest.isNew ? hueAccent : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .failure(let refusal):
                Text(refusal.sentence)
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(SemanticColor.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { text = s + "/" } label: {
                            Text(s).scaledFont(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
                        }
                        .buttonStyle(.hoverAffordance(.inline))
                        .help("Use the folder you already have")
                    }
                }
            }
            HStack {
                Spacer()
                // No key equivalents (BareKeyEquivalentScanTests): the field files on Return, and
                // the popover closes on Esc by itself.
                Button("Cancel", action: onDone).controlSize(.small)
                Button(commitTitle, action: commit)
                    .buttonStyle(.borderedProminent).accentedProminent().controlSize(.small)
                    .disabled({ if case .success = checked { return false } else { return true } }())
            }
        }
        .padding(12)
        .frame(width: 420)
        .onAppear { text = hooks.initial; recheck(); focused = true }
        .onChange(of: text) { recheck() }
    }

    private var commitTitle: String {
        if case .success(let d) = checked, !d.isNew { return hooks.commitTitle.replacingOccurrences(of: "Create and File", with: "File") }
        return hooks.commitTitle
    }

    private func recheck() {
        checked = hooks.validate(text)
        suggestions = hooks.complete(text).filter { $0.lowercased() != text.lowercased() }
    }

    private func commit() {
        guard !committed, case .success(let dest) = checked else { return }
        committed = true
        hooks.onCommit(dest)
        onDone()
    }
}

enum FilingPathEditorText {
    /// "Creates Lease › Statements" or "Files into a folder you already have".
    static func preview(_ dest: FilingDestination) -> String {
        dest.isNew ? "Creates " + dest.newSegments.joined(separator: " › ") + " when you file"
                   : "Files into a folder you already have"
    }
}
