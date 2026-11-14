import Design
import Sync
import SwiftUI

/// Organize ▸ the rename backlog, sectioned by operation, most consequential first
/// (`RenameCategories`). Each section carries its own definition and bulk button, so accepting
/// hundreds of mechanical pads never shares a click with a few judgment calls. Within a section,
/// folders are cards in path order, each listing its renames in two aligned columns.
///
/// One card per folder, the unit the planner decides and the manager applies. A mixed folder lives
/// in its most consequential section and its other steps ride along, as through its own button.
struct RenamePassLens: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var syncManager: FileSyncManager
    let plans: [RenamePlan]
    /// Names that will not store cleanly (this provider's rules, plus the invisible hazards
    /// `NameNormalizer` flags on every provider), leading the list as a "to fix" section when there
    /// are any. Error-tier red, not caution: unlike the rest of the backlog, none is housekeeping.
    var riskyNames: [RiskyName] = []
    let accent: Color
    let onApply: ([RenamePlan]) -> Void
    /// Applies the safe rename to the given risky rows as one undoable batch (the host wires
    /// `normalizeNames`).
    var onFix: ([RiskyName]) -> Void = { _ in }
    let onReveal: (String) -> Void

    /// Plans whose full rename list is shown — see ``stepsBeforeFold``. Not a disclosure: a
    /// card always shows its renames, and this only un-caps a long one.
    @State private var showingAll: Set<String> = []

    /// The sectioning, remembered between renders. `RenameCategories.sections` sorts up to ~1,200
    /// plans, and `body` re-runs on every publish the manager makes. Keyed on the plan list, whose
    /// `==` short-circuits on storage identity, so an unrelated publish costs a pointer comparison.
    /// `leftAlone` rides along because it walks the same list.
    @State private var sectionMemo = LensWorkspaceView.RenderMemo<
        [RenamePlan], (sections: [RenameCategories.Section], leftAlone: [RenamePlan])>()

    /// No collapsible layers: no folder needs a chevron opened before it can be read. `pad`, the
    /// bulk section, comes last, so collapsing it would only save scrolling past the end. Bulk
    /// actions are each section's `Rename All` and each card's `Rename n`.
    var body: some View {
        let grouped = sectionMemo.value(for: plans) {
            (sections: RenameCategories.sections(plans),
             leftAlone: RenameCategories.leftAlone(plans))
        }
        let sections = grouped.sections
        let leftAlone = grouped.leftAlone
        GeometryReader { geo in
            let columns = LensCardGrid.columns(forWidth: geo.size.width,
                                               minimumCardWidth: Self.minimumCardWidth)
            List {
                if !riskyNames.isEmpty {
                    toFixSection
                }
                ForEach(sections, id: \.category) { section in
                    Section {
                        cardRows(section.plans, columns: columns)
                    } header: {
                        categoryHeader(section)
                    }
                }
                if !leftAlone.isEmpty {
                    Section {
                        cardRows(leftAlone, columns: columns)
                    } header: {
                        leftAloneHeader(leftAlone)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    /// The cards, laid out across the pane — see ``LensCardGrid``. One `List` row per grid
    /// row, so the list keeps its own scrolling and reuse rather than becoming one tall stack.
    @ViewBuilder
    private func cardRows(_ plans: [RenamePlan], columns: Int) -> some View {
        // Identified by the row's first plan, not its index (``LensCardGrid/IdentifiedRow``): the
        // list is sectioned, so index ids would collide across sections.
        ForEach(LensCardGrid.identifiedRows(plans, columns: columns)) { gridRow in
            let row = gridRow.items
            HStack(alignment: .top, spacing: LensCardGrid.gutter) {
                ForEach(row) { plan in
                    // One card per folder, its renames inside it, as every Organize lens draws
                    // its unit.
                    planCard(plan)
                }
                // A short last row must not stretch its cards over the width the missing ones
                // would have held — three cards and then one full-width card is not a grid.
                if row.count < columns {
                    ForEach(0..<(columns - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                    }
                }
            }
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: LensCardGrid.gutter / 2, leading: 8,
                                      bottom: LensCardGrid.gutter / 2, trailing: 8))
            .listRowBackground(Color.clear)
        }
    }

    // MARK: The to-fix section (the folded Names lens)

    /// A risky name with its invisible characters made visible: an affix or exotic space as "␣",
    /// a zero-width scalar as "◌", in the error tier this section wears. Without it,
    /// "report.pdf → report.pdf" (differing by a character with no width) shows nothing.
    ///
    /// An `AttributedString`, not a per-character `HStack`, so the row keeps `lineLimit(1)` and
    /// middle truncation. The rule is ``InvisibleNameMarking`` (Sync), shared with the kept-names
    /// list in Settings ▸ Organize; the tint is the caller's (that list wears caution).
    static func marked(_ name: String) -> AttributedString {
        var out = AttributedString()
        for cell in InvisibleNameMarking.cells(for: name) {
            var piece = AttributedString(cell.glyph)
            if cell.isMarker {
                // The marker in the name's own ink; the error is the wash behind it.
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
                    .accessibilityLabel("Reveal in Finder")
                    Button { onFix([risky]) } label: {
                        Text("Fix")
                            .scaledFont(.caption)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderless)
                    .buttonWordsTint(accent)
                    .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
                    .lockedDuringRun()
                    .help("Rename to a name every provider can store, as one undoable change")
                }
                .padding(.vertical, 2)
                .padding(.leading, 14)
            }
        } header: {
            HStack(spacing: 8) {
                Pill(.mini, tint: SemanticColor.error,
                     count: riskyNames.count, label: "to fix")
                // Two classes: `NameNormalizer.risky` also reports hidden characters on every
                // provider, so an iCloud or folder source with no naming rules still fills this
                // section, and the copy names both.
                Text("Names this provider rejects, plus hidden characters any cloud mangles.")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button { onFix(riskyNames) } label: {
                    Text("Fix All \(riskyNames.count)")
                        .scaledFont(.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .buttonWordsTint(SemanticColor.error)
                .layoutPriority(1)
                .fixedSize()
                .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
                .lockedDuringRun()
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

    /// The one structural layer on this screen, drawn as a heading: the standard pill, its bulk
    /// button, and the definition on a line of its own, free to wrap on a narrow pane.
    private func categoryHeader(_ section: RenameCategories.Section) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Pill(.standard, tint: tint(section.category),
                     count: section.kindCount, label: section.category.label)
                Text(section.plans.count == 1 ? "in 1 folder"
                                              : "in \(section.plans.count) folders")
                    .scaledFont(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                Spacer(minLength: 8)
                Button {
                    onApply(section.plans)
                } label: {
                    Text("Rename All \(section.fileCount)")
                        .scaledFont(.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .buttonWordsTint(section.category == .pad ? accent : tint(section.category))
                .layoutPriority(1)
                .fixedSize()
                .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
                .lockedDuringRun()
                .help("Apply every rename in this section’s folders, as one undoable change"
                      + (section.fileCount == section.kindCount ? ""
                         : " — includes the folders’ other pending renames, since a folder is applied whole"))
            }
            Text(section.category.definition)
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // MARK: Folder cards

    /// One folder's renames as a card: what is happening, said once, then every name in two
    /// aligned columns. The renames are the content, so they are not behind a disclosure.
    @ViewBuilder
    private func planCard(_ plan: RenamePlan) -> some View {
        let shown = showingAll.contains(plan.id) ? plan.steps
                                                 : Array(plan.steps.prefix(Self.stepsBeforeFold))
        VStack(alignment: .leading, spacing: 9) {
            planCardHeader(plan)
            if let banner = Self.banner(for: plan) { planBanner(banner) }
            if !plan.steps.isEmpty { RenameColumnsTable(steps: shown) }
            if plan.steps.count > Self.stepsBeforeFold {
                Button {
                    if showingAll.contains(plan.id) { showingAll.remove(plan.id) }
                    else { showingAll.insert(plan.id) }
                } label: {
                    Text(showingAll.contains(plan.id)
                         ? "Show fewer"
                         : "Show \(plan.steps.count - Self.stepsBeforeFold) more")
                        .scaledFont(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(accent)
                .chromeHover()
            }
            ForEach(plan.skips) { skip in skipRow(skip) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lensCard()
    }

    /// Below this a renames card cannot hold its two name columns without truncating both, so a
    /// second grid column is worse than the margin it would fill. Sized for two 18-character
    /// monospaced names at 11pt, the gutter, the padding, and "Rename 12" after the folder name.
    /// Larger than the duplicates lens's minimum, because this card carries a table.
    static let minimumCardWidth: CGFloat = 340

    /// How many renames a card shows before folding the rest: past ten the column stops being
    /// scannable in one look.
    static let stepsBeforeFold = 10

    private func planCardHeader(_ plan: RenamePlan) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 8) {
                Text(RenameCategories.leaf(of: plan.relativePath))
                    .scaledFont(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(plan.steps.count == 1 ? "1 file" : "\(plan.steps.count) files")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button { onReveal(plan.folderPath) } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.plain)
                .chromeHover()
                .help("Reveal this folder in Finder")
                .accessibilityLabel("Reveal this folder in Finder")

                if !plan.steps.isEmpty {
                    Button { onApply([plan]) } label: {
                        Text("Rename \(plan.steps.count)")
                            .scaledFont(.caption)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderless)
                    .buttonWordsTint(accent)
                    .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
                    .lockedDuringRun()
                    .help("Apply every rename in this folder, as one undoable change")
                }
            }
            // The path is context, so it is demoted under the folder name, not a peer of it.
            Text(plan.relativePath)
                .scaledFont(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    /// What every rename in this folder has in common: the pattern where there is one, and the
    /// sentence the steps agree on. nil when there is neither; nothing is invented here.
    static func banner(for plan: RenamePlan) -> (pattern: (before: String, after: String)?,
                                                 reason: String)? {
        guard let sample = plan.steps.first else { return nil }
        let edit = RenamePlanSummary.sharedEdit(plan.steps)
        let pattern = edit.flatMap { RenamePlanSummary.pattern(for: $0, sample: sample) }
        guard let reason = RenamePlanSummary.sharedReason(plan.steps) else {
            return pattern.map { ($0, "") }
        }
        return (pattern, reason)
    }

    @ViewBuilder
    private func planBanner(_ banner: (pattern: (before: String, after: String)?,
                                       reason: String)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let pattern = banner.pattern {
                HStack(spacing: 5) {
                    Text(pattern.before)
                        .foregroundStyle(.secondary)
                    Image(systemName: "arrow.right")
                        .scaledFont(.system(size: 8, weight: .semibold))
                        .accessibilityHidden(true)
                    Text(pattern.after)
                        .fontWeight(.bold)
                }
                .scaledFont(.system(size: 11, design: .monospaced))
                .foregroundStyle(ChromeInk.semantic(colorScheme, SemanticColor.success))
                .fixedSize()
            }
            if !banner.reason.isEmpty {
                Text(banner.reason)
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.chip)
            .fill(SemanticColor.success.opacity(0.10)))
        .accessibilityElement(children: .combine)
    }

    // MARK: Left alone

    /// Plans the pass looked at and declined to touch: a quiet footnote, with no pill and no
    /// button, so it reads as the end of the list rather than a fourth thing to act on.
    private func leftAloneHeader(_ plans: [RenamePlan]) -> some View {
        Text("\(plans.count) folder\(plans.count == 1 ? "" : "s") left alone — every file kept its name, each for a stated reason")
            .scaledFont(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    /// A file the pass deliberately did not touch, listed with its reason, because "why is that one
    /// still called `9829custbill…`" is the first question this feature invites.
    @ViewBuilder
    private func skipRow(_ skip: RenameSkip) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "minus.circle")
                .scaledFont(.caption2)
                // A glyph, so the 3:1 treatment, as in `RiskyNameBadge`.
                .foregroundStyle(ChromeInk.semantic(colorScheme, SemanticColor.caution))
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
    }
}
