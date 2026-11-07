import Design
import SwiftUI
import Sync

/// The removal step: a separate, opt-in sheet over a list the caller resolved, either the
/// folders one landing emptied or folders already empty when the survey looked (``isStanding``).
/// Never an unbounded sweep: every folder is listed, re-probed and ticked one by one. An empty
/// date bucket is debt and starts ticked; an empty category is a destination and does not. No
/// file is ever deleted; folders go to the Trash.
struct RestructureRemovalSheet: View {

    struct Candidate: Equatable, Identifiable {
        let path: String
        /// Re-probed by the caller at open: a folder that gained a file since is shown disabled,
        /// never silently droppable.
        let isStillEmpty: Bool
        /// Whether the folder stands on disk at all. One already in the Trash (the sheet
        /// reopened after its own landing) reads "already removed", not "no longer empty".
        var exists: Bool = true
        var id: String { path }

        var isDateBucket: Bool { Self.isDateBucket(path) }

        /// A bare year or a year span is a date bucket; anything else is a category name, and an
        /// empty category is a destination someone chose.
        static func isDateBucket(_ path: String) -> Bool {
            FolderProfileEntry.looksLikeYear((path as NSString).lastPathComponent)
        }
    }

    let candidates: [Candidate]
    let accent: Color
    /// True when these are pre-existing empties from the crowding strip, not folders a landing
    /// drained. Only the title and opening sentence differ, but they are the sheet's claim about
    /// where the list came from.
    var isStanding: Bool = false

    /// What one removal landing came back as. Typed, not a `String?` refusal, because "landed,
    /// but the survey refresh failed" is still a landing: treated as a refusal, it would leave
    /// the button armed over already-trashed rows.
    enum RemovalResult: Equatable {
        /// The landing ran. `removed` and `skippedCount` are the engine's own counts, since it
        /// can skip some or every ticked folder (one gained a file, or the parent landing was
        /// undone). `caveat` names a follow-up failure, such as the survey refresh.
        case landed(removed: Int, skippedCount: Int, caveat: String?)
        case refused(String)
    }

    /// The landing sentence, from the counts. Static so its three shapes are testable without
    /// the view.
    static func landedSentence(removed: Int, skippedCount: Int, caveat: String?) -> String {
        var sentence: String
        if removed == 0 {
            sentence = "Nothing was moved — every ticked folder was skipped; each skip is "
                + "named in the log."
        } else if skippedCount > 0 {
            sentence = "Moved \(removed) folder\(removed == 1 ? "" : "s") to the Trash; "
                + "\(skippedCount) skipped (named in the log). Undo This Reorganization on "
                + "the removal’s own card puts the moved ones back."
        } else {
            sentence = "Moved to the Trash — Undo This Reorganization on the removal’s own "
                + "card puts them back, even after a quit."
        }
        // A survey-refresh failure is added to the landing sentence, never replaces it, or it
        // would read as "nothing happened".
        if let caveat { sentence += " But " + caveat }
        return sentence
    }

    /// Trashes the ticked paths as one recorded, undoable landing.
    let onRemove: ([String]) async -> RemovalResult
    let onClose: () -> Void

    @State private var ticked: Set<String> = []
    @State private var seeded = false
    @State private var outcome: String?
    @State private var running = false
    /// True only after a landing succeeded; the button retires then and only then. A refusal
    /// sets `outcome` but keeps the button armed, because refusals here are transient (a scan
    /// running, the store mid-write).
    @State private var landed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.titleText(isStanding: isStanding))
                    .scaledFont(.system(size: 13, weight: .semibold))
                Text(Self.introText(isStanding: isStanding))
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
            // Frozen while the landing runs and once it lands: the probe labels were taken at
            // open, and re-ticking against the changed tree would re-arm the retired button.
            .disabled(running || landed)
            HStack(spacing: 10) {
                if let outcome {
                    Text(outcome)
                        .scaledFont(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                // "Done" only after a landing; after a refusal nothing moved, so "Cancel". Held
                // while the landing runs, or the outcome would arrive in a torn-down view.
                Button(landed ? "Done" : "Cancel") { onClose() }
                    .scaledFont(.system(size: 11))
                    .keyboardShortcut(.cancelAction)
                    .disabled(running)
                Button(removeTitle) { remove() }
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .disabled(ticked.isEmpty || running || landed)
                    .lockedDuringRun()
            }
        }
        .padding(18)
        .frame(width: 480)
        .onAppear(perform: seed)
    }

    /// The title is a claim about provenance too: *emptied* says something drained these, true
    /// only of a landing's folders.
    static func titleText(isStanding: Bool) -> String {
        isStanding ? "Remove empty folders" : "Remove emptied folders"
    }

    /// The sentence under the title: where this list came from, then the rule, which both kinds
    /// share.
    static func introText(isStanding: Bool) -> String {
        let source = isStanding
            ? "Folders that were already empty when the survey looked, and only to the Trash. "
            : "Only folders this reorganization itself emptied, and only to the Trash. "
        return source
            + "Date buckets start ticked — they are debt; an empty category is a destination, "
            + "so it does not."
    }

    private var removeTitle: String {
        "Move \(ticked.count) Folder\(ticked.count == 1 ? "" : "s") to Trash"
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
                // The whole path, inline: there are few enough to read, and the choice is made
                // where the name is.
                Text(candidate.path)
                    .scaledFont(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .toggleStyle(.checkbox)
            .help(!candidate.isStillEmpty
                  ? (candidate.exists ? "Can’t be removed — it’s no longer empty" : "Already removed")
                  : ticked.contains(candidate.path) ? "Leave this empty folder out — it stays where it is"
                                                    : "Include this empty folder in the move to the Trash")
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
            case .landed(let removed, let skippedCount, let caveat):
                landed = true
                outcome = Self.landedSentence(removed: removed, skippedCount: skippedCount,
                                              caveat: caveat)
            case .refused(let refusal):
                outcome = refusal
            }
        }
    }
}
