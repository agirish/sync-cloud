import Design
import Sync
import SwiftUI

/// What the roster governs across the whole tree, and the people it does not reach.
///
/// **The gap is the actionable half, and it is normally empty.** A survey records a person axis
/// from the folder names it found; a value no one on the roster answers to is somebody with folders
/// and no record — documents naming them are attributed to nobody, and the cross-person rule cannot
/// protect those folders. On a tree whose roster is complete this finds nothing, so the section says
/// so plainly rather than showing an empty space: "everyone in your tree is accounted for" is
/// itself worth reading once.
struct PeopleOverviewRow: View {
    let overview: PeopleOverview
    @ObservedObject var store: PeopleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if overview.claimedFolders > 0 {
                Text(coverageLine)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(overview.unclaimed, id: \.name) { person in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(unclaimedLine(person), systemImage: "person.badge.questionmark")
                        .scaledFont(.caption)
                        .foregroundStyle(SemanticColor.caution)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Add \(person.name)") {
                        store.add(displayName: person.name)
                    }
                    .controlSize(.small)
                }
            }
            if overview.unclaimed.isEmpty, overview.claimedFolders > 0 {
                Label("Everyone your tree files for is on this list.",
                      systemImage: "checkmark.circle")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if !overview.peopleWithNoFolders.isEmpty {
                Text(noFolderLine)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 4)
    }

    private var coverageLine: String {
        let folders = overview.claimedFolders == 1 ? "1 folder" : "\(overview.claimedFolders) folders"
        let docs = overview.claimedDocuments
        guard docs > 0 else { return "\(folders) in your tree belong to someone on this list" }
        return "\(folders) in your tree belong to someone on this list, holding "
            + "\(docs) filed document\(docs == 1 ? "" : "s")"
    }

    private func unclaimedLine(_ person: PeopleOverview.UnclaimedPerson) -> String {
        let folders = person.folders == 1 ? "1 folder is" : "\(person.folders) folders are"
        return "\(folders) recorded for “\(person.name)”, who is not on this list "
            + "(\(person.exampleFolder))"
    }

    /// Named rather than counted: with a roster this size, *which* person is inert is the useful
    /// part, and it is usually one.
    private var noFolderLine: String {
        let names = overview.peopleWithNoFolders.compactMap { id in
            store.people.first { $0.id == id }?.displayName
        }
        guard !names.isEmpty else { return "" }
        let list = names.joined(separator: ", ")
        return names.count == 1
            ? "\(list) has no folder recorded yet, so their record changes nothing so far."
            : "\(list) have no folders recorded yet, so their records change nothing so far."
    }
}
