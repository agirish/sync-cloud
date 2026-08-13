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
    /// The folded Names lens (P10): names that will not store cleanly — this provider's own rules,
    /// plus the invisible hazards `NameNormalizer` flags on **every** provider — leading the list
    /// as a "to fix" section, present only when it reports, like every category here. Error-tier
    /// red, not caution: unlike the rest of the backlog, nothing here is housekeeping.
    var riskyNames: [RiskyName] = []
    let accent: Color
    let onApply: ([RenamePlan]) -> Void
    /// Applies the safe rename to the given risky rows as one undoable batch (the host wires
    /// `normalizeNames`, exactly as the standalone lens did).
    var onFix: ([RiskyName]) -> Void = { _ in }
    let onReveal: (String) -> Void

    /// Folders opened to show their steps. Collapsed by default — the summary line is the claim,
    /// and the detail is there for the row you are unsure about.
    @State private var expanded: Set<String> = []
    /// Groups whose disclosure the user flipped away from their category's default (pad starts
    /// collapsed, judgment categories open — `RenameCategories.groupsStartCollapsed`). A toggled
    /// set, not a collapsed set, so the default keeps applying to groups the next scan adds.
    @State private var toggledGroups: Set<String> = []
    /// Categories the user collapsed whole.
    @State private var collapsedSections: Set<RenameCategories.Category> = []
    /// For the shared trailing Rename column — measured at the live scale.
    @Environment(\.appFontScale) private var appFontScale

    private func groupKey(_ category: RenameCategories.Category,
                          _ group: RenameCategories.Group) -> String {
        "\(category)|\(group.parent)"
    }

    private func isGroupCollapsed(_ category: RenameCategories.Category,
                                  _ group: RenameCategories.Group) -> Bool {
        RenameCategories.isCollapsed(category: category,
                                     toggled: toggledGroups.contains(groupKey(category, group)))
    }

    /// One right edge for every Rename control (the row buttons were ragged — each label's own
    /// width put "Rename 7" and "Rename 10" at different x). Derived from the widest label this
    /// list can produce, at the live scale — never a hard-coded constant.
    private var renameSlotWidth: CGFloat {
        let widest = "Rename \(plans.map(\.steps.count).max() ?? 0)"
        return LabelMetrics.width(of: widest,
                                  font: ScaledFont.caption.weight(.semibold),
                                  scale: appFontScale)
    }

    var body: some View {
        let sections = RenameCategories.sections(plans)
        let leftAlone = RenameCategories.leftAlone(plans)
        List {
            if !riskyNames.isEmpty {
                toFixSection
            }
            ForEach(sections, id: \.category) { section in
                Section {
                    if !collapsedSections.contains(section.category) {
                        ForEach(section.groups, id: \.parent) { group in
                            groupHeader(group, in: section)
                            if !isGroupCollapsed(section.category, group) {
                                ForEach(group.plans) { plan in
                                    planRow(plan, category: section.category)
                                    if expanded.contains(plan.id) {
                                        expandedRows(plan)
                                    }
                                }
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

    // MARK: The to-fix section (the folded Names lens)

    /// A risky name with its invisible characters made visible — an affix or exotic space as "␣",
    /// a zero-width scalar as "◌", both in the error tier this section wears.
    ///
    /// **Restored here after the fold dropped it.** The retired standalone lens drew every risky
    /// name through this rule; when the findings moved into this section (v4.0 polish P10) they
    /// came as a plain `Text`, and a whole class of finding stopped being legible: `NameNormalizer`
    /// flags a hidden zero-width scalar or a non-standard space on **every** provider, so
    /// "report.pdf → report.pdf" — identical to the eye, differing by a character that has no
    /// width — is the ordinary case here, not an edge one. The reason line still named the problem
    /// in words; the name itself showed nothing.
    ///
    /// An `AttributedString` rather than the old per-character `HStack`, so the row keeps the
    /// `lineLimit(1)` and middle truncation every other name in this lens has. The retired view
    /// laid its cells out in an HStack and carried a `lineLimit` that could not truncate one, so a
    /// long name pushed the row instead of eliding.
    ///
    /// The rule is ``InvisibleNameMarking`` (Sync), shared with the kept-names list in
    /// Settings ▸ Organize so the two cannot disagree about how many trailing spaces a name has.
    /// The tint is the caller's: that list wears caution (a name you chose to keep), this section
    /// wears error (a name that is still broken).
    static func marked(_ name: String) -> AttributedString {
        var out = AttributedString()
        for cell in InvisibleNameMarking.cells(for: name) {
            var piece = AttributedString(cell.glyph)
            if cell.isMarker {
                piece.foregroundColor = SemanticColor.error
                piece.backgroundColor = SemanticColor.error.opacity(PillVariant.fillOpacity)
            }
            out.append(piece)
        }
        return out
    }

    /// Names the provider rejects, above every category: the one kind of rename that isn't
    /// housekeeping — sync fails until these change — so it opens the list and wears the error
    /// tier. Rendered only when it reports; a clean name check adds no empty section.
    private var toFixSection: some View {
        Section {
            ForEach(riskyNames) { risky in
                HStack(spacing: 8) {
                    Image(systemName: RiskyNameGlyph.risky)
                        .scaledFont(.caption)
                        .foregroundStyle(SemanticColor.error)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(Self.marked(risky.currentName))
                                .scaledFont(.callout)
                                .fontWeight(.medium)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "arrow.right")
                                .scaledFont(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(risky.sanitizedName)
                                .scaledFont(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text("\(risky.relativePath) — \(risky.reason)")
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    Button { onReveal(risky.id) } label: {
                        Image(systemName: "arrow.up.forward.app")
                    }
                    .buttonStyle(.plain)
                    .chromeHover()
                    .help("Reveal in Finder")
                    Button { onFix([risky]) } label: {
                        Text("Fix")
                            .scaledFont(.caption)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderless)
                    .tint(accent)
                    .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
                    .help("Rename to a name every provider can store, as one undoable change")
                }
                .padding(.vertical, 2)
                .padding(.leading, 14)
            }
        } header: {
            HStack(spacing: 8) {
                Pill(.mini, tint: SemanticColor.error,
                     count: riskyNames.count, label: "to fix")
                // **Two classes, and the copy used to name one.** `NameNormalizer.risky` reports a
                // name when its sanitized form differs, and sanitize's first layer runs "always,
                // for every provider" — zero-width scalars dropped, exotic whitespace folded — so
                // an iCloud or folder source, which has no naming rules of its own, still fills
                // this section. "Names this provider will not accept" was false for exactly those
                // sources, and "sync breaks until they change" overstated the invisible class,
                // whose own reason line says it "can create invisible duplicates".
                Text("Names this provider rejects, plus hidden characters any cloud mangles.")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { onFix(riskyNames) } label: {
                    Text("Fix all \(riskyNames.count)")
                        .scaledFont(.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(SemanticColor.error)
                .layoutPriority(1)
                .fixedSize()
                .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
                .help("Rename every listed name to its safe form, as one undoable batch")
            }
            .padding(.vertical, 2)
        }
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
            Button {
                if collapsedSections.contains(section.category) {
                    collapsedSections.remove(section.category)
                } else {
                    collapsedSections.insert(section.category)
                }
            } label: {
                Image(systemName: collapsedSections.contains(section.category)
                        ? "chevron.right" : "chevron.down")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .chromeHover()
            .help(collapsedSections.contains(section.category)
                    ? "Show this section" : "Hide this section")
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
            Button {
                let key = groupKey(section.category, group)
                if toggledGroups.contains(key) { toggledGroups.remove(key) }
                else { toggledGroups.insert(key) }
            } label: {
                Image(systemName: isGroupCollapsed(section.category, group)
                        ? "chevron.right" : "chevron.down")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            .chromeHover()
            .help(isGroupCollapsed(section.category, group)
                    ? "Show these folders" : "Hide these folders")
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
            Button { onApply(group.plans) } label: {
                Text("Rename \(group.fileCount)")
                    .scaledFont(.caption)
                    .fontWeight(.semibold)
                    .frame(minWidth: renameSlotWidth, alignment: .trailing)
            }
            .buttonStyle(.borderless)
            .tint(accent)
            .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
            .help("Apply every rename under “\(group.parent.isEmpty ? "the top level" : group.parent)”, as one undoable change")
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
                        .frame(minWidth: renameSlotWidth, alignment: .trailing)
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
