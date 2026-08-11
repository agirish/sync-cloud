import Design
import Sync
import SwiftUI

/// Organize ▸ the rename backlog, category-first (v4.0 polish P10).
///
/// The screen used to be one flat list: 132 near-identical folder rows whose only distinction —
/// what the pass would *do* — hid in an 11pt caption, with one giant "Rename 641 files" and 132
/// row links as the only granularities. It is now sectioned by operation, most consequential
/// first (`RenameCategories`): naming is a judgment about intent, a reshuffle touches files that
/// were already correct, a pad is mechanical — and each section carries its own definition and
/// its own bulk button, so accepting 628 mechanical pads never shares a click with 7 judgment
/// calls. Within a section, folders group under their immediate parent directory, the parent
/// stated once and dimmed; every row proves its claim with one inline before → after sample.
///
/// One row per **folder** still, because that is the unit the planner decides and the unit the
/// manager applies: a plan's steps are chosen against each other, so half of one is not a
/// smaller version of the same change. A mixed folder lives in its most consequential section
/// and its other steps ride along, exactly as they do through its own Rename button.
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
        let sections = RenameCategories.sections(plans)
        let leftAlone = RenameCategories.leftAlone(plans)
        List {
            ForEach(sections, id: \.category) { section in
                Section {
                    ForEach(section.groups, id: \.parent) { group in
                        groupHeader(group, in: section)
                        ForEach(group.plans) { plan in
                            planRow(plan, category: section.category)
                            if expanded.contains(plan.id) {
                                expandedRows(plan)
                            }
                        }
                    }
                } header: {
                    categoryHeader(section)
                }
            }
            if !leftAlone.isEmpty {
                leftAloneSection(leftAlone)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
    }

    // MARK: Category sections

    /// The section's tint: naming takes the accent, a reshuffle wears the caution tier (the one
    /// operation that moves a file which was already correct — "your call"), a pad stays quiet.
    private func tint(_ category: RenameCategories.Category) -> Color {
        switch category {
        case .name: return accent
        case .reshuffle: return SemanticColor.caution
        case .pad: return .secondary
        }
    }

    private func categoryHeader(_ section: RenameCategories.Section) -> some View {
        HStack(spacing: 8) {
            Pill(.mini, tint: tint(section.category),
                 count: section.kindCount, label: section.category.label)
            Text(section.category.definition)
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button {
                onApply(section.plans)
            } label: {
                Text("Rename all \(section.fileCount)")
                    .scaledFont(.caption)
                    .fontWeight(.semibold)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(section.category == .pad ? accent : tint(section.category))
            .layoutPriority(1)
            .fixedSize()
            .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
            .help("Apply every rename in this section's folders, as one undoable change"
                  + (section.fileCount == section.kindCount ? ""
                     : " — includes the folders' other pending renames, since a folder is applied whole"))
        }
        .padding(.vertical, 2)
    }

    /// The parent directory, stated once and dimmed, with the middle granularity the flat list
    /// never had: a Rename for just this group of folders.
    private func groupHeader(_ group: RenameCategories.Group,
                             in section: RenameCategories.Section) -> some View {
        HStack(spacing: 8) {
            Text(group.parent.isEmpty ? "Top level" : group.parent + "/")
                .scaledFont(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Text("\(group.plans.count) folder\(group.plans.count == 1 ? "" : "s") · \(group.fileCount) file\(group.fileCount == 1 ? "" : "s")")
                .scaledFont(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Spacer(minLength: 8)
            if group.plans.count > 1 {
                Button { onApply(group.plans) } label: {
                    Text("Rename \(group.fileCount)")
                        .scaledFont(.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderless)
                .tint(accent)
                .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
                .help("Apply every rename under “\(group.parent.isEmpty ? "the top level" : group.parent)”, as one undoable change")
            }
        }
        .padding(.top, 4)
    }

    // MARK: Folder rows

    @ViewBuilder
    private func planRow(_ plan: RenamePlan, category: RenameCategories.Category) -> some View {
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
                Text(RenameCategories.leaf(of: plan.relativePath))
                    .scaledFont(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                // The row's proof: one rename of this section's own kind, before → after —
                // what "10 to pad" actually looks like, without opening the chevron.
                if let sample = RenameCategories.sampleStep(plan, category: category) {
                    HStack(spacing: 4) {
                        Text(sample.currentName)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "arrow.right")
                            .scaledFont(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(sample.proposedName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if plan.steps.count > 1 {
                            Text("· +\(plan.steps.count - 1) more")
                                .foregroundStyle(.tertiary)
                                .fixedSize()
                        }
                    }
                    .scaledFont(.system(size: 11, design: .monospaced))
                } else {
                    Text(Self.summary(plan))
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)

            Button { onReveal(plan.folderPath) } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.plain)
            .chromeHover()
            .help("Reveal this folder in Finder")

            // No button on a plan of nothing but skips — "Rename 0" would be a zero the rest
            // of this screen refuses to draw.
            if !plan.steps.isEmpty {
                Button { onApply([plan]) } label: {
                    Text("Rename \(plan.steps.count)")
                        .scaledFont(.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderless)
                .tint(accent)
                // Disabled during a rescan as well as during an apply, matching the header's
                // "Rename all". A plan is last scan's answer until the new one publishes, and a
                // button that acts on it mid-scan is offering a claim the app is in the middle of
                // revising.
                .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
                .help("Apply every rename in this folder, as one undoable change")
            }
        }
        .padding(.vertical, 2)
        .padding(.leading, 14)
    }

    /// The expanded plan: every step and skip. Reasons are stated where they change — nine
    /// consecutive "Padded to two digits…" lines were wallpaper, so a step's reason draws only
    /// when it differs from the previous step's, and the exceptions keep their captions.
    @ViewBuilder
    private func expandedRows(_ plan: RenamePlan) -> some View {
        let steps = plan.steps
        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
            stepRow(step, showsReason: index == 0 || steps[index - 1].reason != step.reason)
        }
        ForEach(plan.skips) { skip in skipRow(skip) }
    }

    // MARK: Left alone

    /// Plans the pass looked at and declined to touch — a quiet footnote, not peer rows: there
    /// is nothing to do here, and the reasons are the payload.
    private func leftAloneSection(_ plans: [RenamePlan]) -> some View {
        Section {
            ForEach(plans) { plan in
                planRow(plan, category: .pad)
                if expanded.contains(plan.id) {
                    expandedRows(plan)
                }
            }
        } header: {
            Text("\(plans.count) folder\(plans.count == 1 ? "" : "s") left alone — every file kept its name, each for a stated reason")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    /// The one-line claim under a folder's name (used when a row has no sample to show).
    ///
    /// Pure and static so the wording is testable without mounting anything — and it says both
    /// halves, because "8 renames" over a plan that also declined to touch two files reads as a
    /// pass that saw eight files in a folder of ten.
    ///
    /// The sentence itself is ``RenameBacklogTally/claim``, which the header above this list also
    /// draws over *every* plan at once.
    static func summary(_ plan: RenamePlan) -> String {
        RenameBacklogTally([plan]).claim
    }

    @ViewBuilder
    private func stepRow(_ step: RenameStep, showsReason: Bool = true) -> some View {
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
            if showsReason {
                Text(step.reason)
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .padding(.leading, 34)
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
        .padding(.leading, 34)
    }
}
