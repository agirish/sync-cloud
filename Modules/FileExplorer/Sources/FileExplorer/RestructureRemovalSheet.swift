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
    /// Trashes the ticked paths as one recorded, undoable landing; returns a refusal sentence or
    /// nil on success.
    let onRemove: ([String]) async -> String?
    let onClose: () -> Void

    @State private var ticked: Set<String> = []
    @State private var seeded = false
    @State private var outcome: String?
    @State private var running = false

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
                Button(outcome == nil ? "Cancel" : "Done") { onClose() }
                    .scaledFont(.system(size: 11))
                Button(removeTitle) { remove() }
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .disabled(ticked.isEmpty || running || outcome != nil)
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
                 : "no longer empty")
                .scaledFont(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private func remove() {
        let paths = ticked.sorted()
        running = true
        Task { @MainActor in
            let refusal = await onRemove(paths)
            running = false
            outcome = refusal ?? "Moved to the Trash — Undo this reorganisation on the "
                + "removal's own card puts them back, even after a quit."
        }
    }
}
