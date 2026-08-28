import Design
import SwiftUI
import Sync

/// §5.5's removal step: a separate sheet, opt-in, scoped to the folders one landing itself
/// emptied — never a general empties sweep. Split by the shape of the name: an empty **date
/// bucket** is debt and starts ticked; an empty **category** is a destination and does not, its
/// path printed where the choice is made. No file is ever deleted; folders go to the Trash.
struct RestructureRemovalSheet: View {

    struct Candidate: Equatable, Identifiable {
        let path: String
        /// Re-probed by the caller at open — a folder that gained a file since the landing is
        /// shown disabled with the truth, never silently droppable.
        let isStillEmpty: Bool
        /// Whether the folder stands on disk at all. A candidate already in the Trash (the
        /// sheet reopened after its own landing) is "already removed" — labelling it
        /// "no longer empty" would claim it gained content it never had.
        var exists: Bool = true
        var id: String { path }

        var isDateBucket: Bool { Self.isDateBucket(path) }

        /// The split §5.5 orders: a bare year or a year span is a date bucket; anything else is
        /// a category name, and an empty category is a destination someone chose.
        static func isDateBucket(_ path: String) -> Bool {
            FolderProfileEntry.looksLikeYear((path as NSString).lastPathComponent)
        }
    }

    let family: String
    let candidates: [Candidate]
    let accent: Color

    /// What one removal landing came back as. A TYPED outcome, not a `String?` refusal, because
    /// "landed, but the survey refresh failed" is a landing — the folders ARE in the Trash —
    /// and carrying that sentence through a refusal channel left the button armed over
    /// already-trashed rows, where a second click minted a junk all-skip ledger record.
    enum RemovalResult: Equatable {
        /// The folders were trashed; `caveat` names a follow-up failure (the survey refresh)
        /// when there was one.
        case landed(caveat: String?)
        case refused(String)
    }

    /// Trashes the ticked paths as one recorded, undoable landing.
    let onRemove: ([String]) async -> RemovalResult
    let onClose: () -> Void

    @State private var ticked: Set<String> = []
    @State private var seeded = false
    @State private var outcome: String?
    @State private var running = false
    /// True only after a landing SUCCEEDED — the button retires then, and only then. A refusal
    /// leaves `outcome` set for the sentence but must not kill the button: the refusals here
    /// are transient (a scan running, the store mid-write), and a dead Remove behind one made
    /// close-and-reopen the only retry.
    @State private var landed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Remove emptied folders")
                    .scaledFont(.system(size: 13, weight: .semibold))
                Text("Only folders this reorganisation itself emptied, and only to the Trash. "
                     + "Date buckets start ticked — they are debt; an empty category is a "
                     + "destination, so it does not.")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(candidates) { candidate in
                        row(candidate)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            HStack(spacing: 10) {
                if let outcome {
                    Text(outcome)
                        .scaledFont(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                // "Done" only after the landing landed — a refusal closes as "Cancel" (nothing
                // moved). Held while the landing runs: dismissing mid-run would swallow the
                // outcome sentence in a torn-down view.
                Button(landed ? "Done" : "Cancel") { onClose() }
                    .scaledFont(.system(size: 11))
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                Button(removeTitle) { remove() }
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .disabled(ticked.isEmpty || running || landed)
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear(perform: seed)
    }

    private var removeTitle: String {
        "Move \(ticked.count) folder\(ticked.count == 1 ? "" : "s") to Trash"
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        ticked = Set(candidates.filter { $0.isStillEmpty && $0.isDateBucket }.map(\.path))
    }

    private func row(_ candidate: Candidate) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { ticked.contains(candidate.path) },
                set: { on in
                    if on { ticked.insert(candidate.path) } else { ticked.remove(candidate.path) }
                }
            )) {
                // The whole path, inline — there are few enough to read, and the choice is made
                // where the name is (§5.5).
                Text(candidate.path)
                    .scaledFont(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .toggleStyle(.checkbox)
            .disabled(!candidate.isStillEmpty)
            Spacer(minLength: 4)
            Text(candidate.isStillEmpty
                 ? (candidate.isDateBucket ? "date bucket" : "category")
                 : (candidate.exists ? "no longer empty" : "already removed"))
                .scaledFont(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func remove() {
        guard !running, !landed else { return }
        let paths = ticked.sorted()
        running = true
        outcome = nil
        Task { @MainActor in
            let result = await onRemove(paths)
            running = false
            switch result {
            case .landed(let caveat):
                landed = true
                // A survey-refresh failure after a SUCCESSFUL trashing composes with the
                // landing, never replaces it: a sentence that only named the failure read as
                // "nothing happened" over a sheet whose button had gone dead.
                outcome = caveat.map { "Moved to the Trash — but " + $0 }
                    ?? "Moved to the Trash — Undo this reorganisation on the removal's own "
                        + "card puts them back, even after a quit."
            case .refused(let refusal):
                outcome = refusal
            }
        }
    }
}
