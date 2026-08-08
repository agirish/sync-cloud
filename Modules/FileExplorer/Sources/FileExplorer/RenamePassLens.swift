import Design
import Sync
import SwiftUI

/// Organize ▸ the rename backlog. One row per **folder**, because that is the unit the planner
/// decides and the unit the manager applies: a plan's steps are chosen against each other, so half
/// of one is not a smaller version of the same change.
///
/// A row shows the folder, what the pass would do to it, and — expanded — every rename in full,
/// old name beside new. Nothing is hidden behind a count: a rename you cannot read before accepting
/// is a rename you have to undo to inspect.
struct RenamePassLens: View {
    @ObservedObject var syncManager: FileSyncManager
    let plans: [RenamePlan]
    let accent: Color
    let onApply: ([RenamePlan]) -> Void
    let onReveal: (String) -> Void

    /// Folders opened to show their steps. Collapsed by default — the summary line is the claim,
    /// and the detail is there for the row you are unsure about.
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            ForEach(plans) { plan in
                Section {
                    if expanded.contains(plan.id) {
                        ForEach(plan.steps) { step in stepRow(step) }
                        ForEach(plan.skips) { skip in skipRow(skip) }
                    }
                } header: {
                    header(plan)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private func header(_ plan: RenamePlan) -> some View {
        HStack(spacing: 8) {
            Button {
                if expanded.contains(plan.id) { expanded.remove(plan.id) } else { expanded.insert(plan.id) }
            } label: {
                Image(systemName: expanded.contains(plan.id) ? "chevron.down" : "chevron.right")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .chromeHover()
            .help(expanded.contains(plan.id) ? "Hide the renames" : "Show every rename in this folder")

            VStack(alignment: .leading, spacing: 1) {
                Text(plan.relativePath)
                    .scaledFont(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(Self.summary(plan))
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)

            Button { onReveal(plan.folderPath) } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .chromeHover()
            .help("Reveal this folder in Finder")

            Button { onApply([plan]) } label: {
                Text("Rename \(plan.steps.count)")
                    .scaledFont(.caption)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderless)
            .tint(accent)
            // Disabled during a rescan as well as during an apply, matching the header's
            // "Rename all". A plan is last scan's answer until the new one publishes, and a button
            // that acts on it mid-scan is offering a claim the app is in the middle of revising.
            .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
            .help("Apply every rename in this folder, as one undoable change")
        }
        .padding(.vertical, 2)
    }

    /// The one-line claim under a folder's name.
    ///
    /// Pure and static so the wording is testable without mounting anything — and it says both
    /// halves, because "8 renames" over a plan that also declined to touch two files reads as a
    /// pass that saw eight files in a folder of ten.
    ///
    /// The sentence itself is ``RenameBacklogTally/claim``, which the header above this list also
    /// draws over *every* plan at once. It was written out twice for one release: the header
    /// summarised the same plans in different words and a different order, which reads as a
    /// different measurement of a different thing rather than as the sum of the rows below it.
    static func summary(_ plan: RenamePlan) -> String {
        RenameBacklogTally([plan]).claim
    }

    @ViewBuilder
    private func stepRow(_ step: RenameStep) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(step.currentName)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.right")
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                Text(step.proposedName)
                    .scaledFont(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            Text(step.reason)
                .scaledFont(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.leading, 20)
    }

    /// A file the pass deliberately did not touch. Shown in the list rather than counted away —
    /// "why is that one still called `9829custbill…`" is the first question this feature invites,
    /// and the answer is already computed.
    @ViewBuilder
    private func skipRow(_ skip: RenameSkip) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "minus.circle")
                .scaledFont(.caption2)
                .foregroundStyle(SemanticColor.caution)
            VStack(alignment: .leading, spacing: 1) {
                Text(skip.fileName)
                    .scaledFont(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(skip.reason)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.leading, 20)
    }
}
