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
    @Environment(\.colorScheme) private var colorScheme
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

    /// Plans whose full rename list is shown — see ``stepsBeforeFold``. Not a disclosure: a
    /// card always shows its renames, and this only un-caps a long one.
    @State private var showingAll: Set<String> = []

    /// The sectioning, remembered between renders.
    ///
    /// `RenameCategories.sections` buckets every plan and then **sorts each bucket by path** — up
    /// to ~1,200 plans on the real backlog — and it ran in `body`, which this lens's host re-runs
    /// on every publish its manager makes. The key is the plan list itself: Swift's `Array ==`
    /// short-circuits on storage identity, so a publish that did not touch the backlog costs a
    /// pointer comparison rather than a sort. `leftAlone` rides along because it walks the same
    /// list. (`LensWorkspaceView.RenderMemo` is the shared one-slot box; it lives there because
    /// that is where it was first needed.)
    @State private var sectionMemo = LensWorkspaceView.RenderMemo<
        [RenamePlan], (sections: [RenameCategories.Section], leftAlone: [RenamePlan])>()

    /// **Two collapsible layers came out of this screen, and nothing replaced them.**
    ///
    /// A card used to sit under a parent-directory row with its own chevron, under a category
    /// header with another — so reading four file names meant two disclosures whose state was not
    /// the reader's question, and the two header rows above the card said between them what the
    /// card's own header and path caption already say. His report: "a little annoying and looks
    /// messy".
    ///
    /// Losing the section chevron costs nothing measurable, which is why it went: sections run
    /// most-consequential-first and `pad` — the bulk one, the reason a default collapse existed —
    /// is last, so collapsing it only ever saved scrolling past the end of the list. What is
    /// genuinely gone is the middle bulk button ("rename just this parent's folders"); the
    /// section's own `Rename all` and each card's `Rename n` remain, and no folder needs a
    /// chevron opened before it can be read.
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
        // Identified by the row's first plan, not by its index — see ``LensCardGrid/IdentifiedRow``.
        // This list is sectioned too, so index ids would collide across sections exactly as they
        // did in Duplicates.
        ForEach(LensCardGrid.identifiedRows(plans, columns: columns)) { gridRow in
            let row = gridRow.items
            HStack(alignment: .top, spacing: LensCardGrid.gutter) {
                ForEach(row) { plan in
                    // **One card per folder, its renames inside it.** These were bare `List`
                    // rows: the folder line and its four steps were sibling rows with system
                    // separators between them, so nothing on screen said which steps belonged
                    // to which folder except indentation. Every other lens in Organize draws
                    // its unit as a `lensCard`; this one did not.
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
                    .accessibilityLabel("Reveal in Finder")
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

    /// The one structural layer left on this screen, so it is drawn as a heading rather than as
    /// another dense row: the standard pill (the design system's own header stat, not the inline
    /// mini this used to wear), its bulk button, and the definition on a line of its own.
    ///
    /// **It was three claims on one 11pt line, above two more header rows.** The definition had a
    /// `lineLimit(1)` and truncated on any pane narrow enough to matter, which is the pane this
    /// lens is usually read in.
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
    /// aligned columns.
    ///
    /// **This replaced a disclosure row.** The old shape put a sample rename on the folder line
    /// and hid the rest behind a chevron — so the first rename appeared twice, 25pt apart, once
    /// as the sample and again as the first hidden row, and reading four files meant opening a
    /// third level of nesting to see something that fits on screen without it. The renames are
    /// the content; they are not folded away.
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

    /// **Below this a renames card cannot hold its two name columns without truncating both**, so
    /// a second column is worse than the empty margin it would fill. Measured against the widest
    /// ordinary case: two 18-character monospaced names at 11pt (~120pt each), the grid gutter, the
    /// card's own padding, and a header that has to fit "Rename 12" after the folder name.
    ///
    /// Deliberately larger than the duplicates lens's minimum — a collapsed duplicates tile carries
    /// one name and a subtitle, this carries a table.
    static let minimumCardWidth: CGFloat = 340

    /// How many renames a card shows before folding the rest. Ten is the point at which the
    /// column stops being scannable in one look; below it the fold costs a click and saves
    /// nothing.
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
                    .tint(accent)
                    .disabled(syncManager.isApplyingRenames || syncManager.isSuggestingFiles)
                    .help("Apply every rename in this folder, as one undoable change")
                }
            }
            // The path is context, so it is demoted rather than given a row of its own — it was
            // a peer of the folder name before, which made one fact read as two.
            Text(plan.relativePath)
                .scaledFont(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.head)
        }
    }

    /// What every rename in this folder has in common — the pattern where there is one, and the
    /// sentence the steps agree on. Absent when they do not agree, in which case the rows carry
    /// their own reasons and nothing is invented here.
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

    /// Every rename, in two aligned columns.
    ///
    /// **Aligned is the point.** `old → new` per row leaves the new names starting at whatever x
    /// the old name happened to end at, so the eye has to re-find the answer on every line. A
    /// column is read once, downward.
    // MARK: Left alone

    /// Plans the pass looked at and declined to touch — a quiet footnote, not peer rows: there
    /// is nothing to do here, and the reasons are the payload. No pill and no button, so it reads
    /// as the end of the list rather than as a fourth thing to act on.
    private func leftAloneHeader(_ plans: [RenamePlan]) -> some View {
        Text("\(plans.count) folder\(plans.count == 1 ? "" : "s") left alone — every file kept its name, each for a stated reason")
            .scaledFont(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
            .padding(.bottom, 4)
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

    /// A file the pass deliberately did not touch. Shown in the list rather than counted away —
    /// "why is that one still called `9829custbill…`" is the first question this feature invites,
    /// and the answer is already computed.
    @ViewBuilder
    private func skipRow(_ skip: RenameSkip) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "minus.circle")
                .scaledFont(.caption2)
                // A glyph, so the 3:1 treatment — see `RiskyNameBadge` for the same call.
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
