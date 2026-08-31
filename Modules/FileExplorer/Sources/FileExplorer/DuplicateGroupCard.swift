import SwiftUI
import Sync
import Design

/// One duplicate group rendered as an expandable card: the common name, a reclaim figure, and —
/// when expanded — each copy with its location, the recommended keeper, and the resolve actions.
/// The match type is named by the SECTION the card sits in, not on the card.
struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    let isExpanded: Bool
    let providerName: String?
    let scanRoot: String?
    /// Row measurements per the appearance density setting (H7), injected by the owner (LensWorkspaceView
    /// reads the @AppStorage once and passes the resolved metrics down); comfortable is the
    /// pre-H7 look.
    let densityMetrics: ListDensityMetrics
    let onToggle: () -> Void
    let onApply: () -> Void
    let onReveal: () -> Void
    let onKeepSeparate: () -> Void
    let onChooseKeeper: (String) -> Void
    let onMerge: () -> Void
    /// Opens two copies of this group side by side in Compare — the keeper on the left (kept), the
    /// chosen redundant copy on the right (the delete candidate). Only surfaced for folder groups;
    /// `var` with a default so the memberwise init keeps it optional for existing call sites/tests.
    var onCompareCopies: (DuplicateCopy, DuplicateCopy) -> Void = { _, _ in }
    /// True while this group's merge is in flight (`FileSyncManager.mergingGroupIDs`): the merge
    /// button becomes an inert "Merging…" indicator and the card's destructive actions disable —
    /// a second click mid-merge would re-plan against the half-merged keeper and mint " 2"
    /// copies. `var` with a default so existing call sites/tests are unaffected.
    var isMerging: Bool = false
    /// How the header lays itself out — see ``DuplicateCardHeaderLayout``.
    ///
    /// **No default, for the reason ``DuplicateThumbnailView/onChoose`` has none.** Defaulted to
    /// `.row` it was a call site that could forget the feature silently: deleting the `headerLayout:`
    /// argument in `LensWorkspaceView` compiled, returned every grid tile to the one-line header,
    /// and left the suite green — while `theRowHeaderOverflowsAGridColumnAndTheStackedOneDoesNot`
    /// proves that header does not fit a grid column. The compiler holds the wiring instead.
    let headerLayout: DuplicateCardHeaderLayout

    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    /// For the invisible-column slot widths (`DuplicateGroupColumns`) — measured at the live scale.
    @Environment(\.appFontScale) private var appFontScale

    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }

    /// The exception treatment's colour — nil on the majority case, which wears no stripe and no
    /// wash (ROADMAP.md, the Identical-badge item): on a real scan `identical` fires on the
    /// overwhelming majority, and rows needing a human decision were wearing identical weight and
    /// getting lost in the run. A row's visual weight now tracks how much attention it deserves.
    ///
    /// **It used to also draw a word, and the word is what the sections made redundant.** A badge
    /// reading "Versions" on every card in a list headed *Versions* states the heading again once
    /// per tile; the stripe and the wash say the same thing without spending a line of the header
    /// on it, so those stayed and the badge went. `badgeLabel` survives as the predicate because
    /// it is still exactly "is this an exception kind" — it is no longer a question about a label
    /// that gets drawn.
    private var severity: Color? {
        DuplicateMatchStyle.badgeLabel(group.matchType) == nil
            ? nil : DuplicateMatchStyle.color(group.matchType)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider().overlay(Color.primary.opacity(0.06))
                body(for: group)
            }
        }
        .lensCard()
        // The faint wash: over the card rather than under it, because `lensCard`'s own fill is
        // what a background would hide behind. 0.035 is a tint on the whole card, not a colour
        // on any text — the stripe carries the semantics, and the section heading the word.
        .overlay {
            if let severity {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(severity.opacity(0.035))
                    .allowsHitTesting(false)
            }
        }
        // The severity stripe: inset rather than corner-flush, so it never fights the card
        // radius, and non-interactive so the header's whole-row button keeps its target.
        .overlay(alignment: .leading) {
            if let severity {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(severity.opacity(0.75))
                    .frame(width: 3)
                    .padding(.vertical, 8)
                    .padding(.leading, 1.5)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        Button(action: onToggle) {
            Group {
                switch headerLayout {
                case .row: rowHeader
                case .stacked: stackedHeader
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, densityMetrics.cardHeaderVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.hoverAffordance(.row, tint: hueAccent))
    }

    /// The full-width header: everything on one line, in the invisible columns.
    ///
    /// Invisible columns (DuplicateGroupColumns): the subtitle right-aligns against the verb
    /// column; verb and digits each hold their own slot so "reclaim 157 KB" and "~24.2 MB shared"
    /// share one digit column instead of two ragged endings.
    ///
    /// **The leading badge slot is gone with the badge**, and with it the reason every name used
    /// to start at one x: names now begin at the icon, which is the same x on every card because
    /// no card carries anything before it. The alignment the slot bought is still bought, by
    /// there being nothing left to vary.
    private var rowHeader: some View {
        HStack(spacing: 12) {
            fileIcon
            Text(titleName)
                .scaledFont(.system(size: 14, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(subtitle)
                .scaledFont(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            reclaimColumns
            disclosureChevron
        }
    }

    /// The stacked header: the same six facts on three short lines.
    ///
    /// **A one-line header stops overflowing at 264pt and is not worth drawing until 380** — a
    /// digits column and a chevron, of which only the name can shed. Measured, and held to the
    /// measurement by `theRowHeaderOverflowsAGridColumnAndTheStackedOneDoesNot`; it was "about
    /// 530" in prose for a while, which is the kind of number this file's own rules say to treat
    /// as a finding. Under it the header draws wider than its card rather than truncating.
    /// (264 is the post-badge bare fit — the badge slot was ~100pt of the old 364. The gap up to
    /// 380 is `rowHeaderNameBudget`: at the bare fit the name has truncated away to nothing, so
    /// "it fits" and "it is readable" are different widths and only the second one matters here.)
    ///
    /// Stacked, the same content reads at 220pt: the figure takes the top line, the name takes the
    /// width of the card, and the subtitle sits under it with the chevron. The invisible columns
    /// are dropped deliberately — they align a figure against its neighbours in the row above and
    /// below, which is a property of a table and not of a grid of tiles.
    private var stackedHeader: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                stackedReclaim
                Spacer(minLength: 4)
            }
            HStack(spacing: 8) {
                fileIcon
                Text(titleName)
                    .scaledFont(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 6) {
                Text(subtitle)
                    .scaledFont(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                disclosureChevron
            }
        }
    }

    private var disclosureChevron: some View {
        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
            .scaledFont(.system(size: 12, weight: .semibold))
            .hoverInk(rest: .tertiary)
    }

    /// **The card is titled with the copy being kept, not with the group's name.**
    ///
    /// The two are the same string whenever the copies share a name, which is most groups. They
    /// are not for the ones where the pick is a real decision: a versions group holds differently
    /// named files by definition, and a same-text group routinely holds `Passport.pdf` beside
    /// `Passport (Jul 2020).pdf`. Titling those with the group's name meant picking the archived
    /// copy left the card still headed by the name of the file about to be trashed — the header
    /// answering a question the rows below it had just answered the other way.
    ///
    /// Falls back to the group name rather than reading ``DuplicateGroup/keeper``, which traps on
    /// a group with no copies; a header is not the place to find that out.
    private var titleName: String {
        group.copies.first(where: { $0.isRecommendedKeeper })?.name ?? group.name
    }

    private var fileIcon: some View {
        // The shared medium vocabulary (FileTypeGlyph), replacing NSWorkspace's raster icon:
        // Storage and Duplicates now draw one file the same way, and a 17pt shape reads as
        // "document / photo / audio" where a shrunken thumbnail read as "rectangle".
        FileTypeGlyph.view(name: group.name, isDirectory: group.isDirectory, pointSize: 14)
            .frame(width: 17, height: 17)
    }

    private var subtitle: String {
        let n = group.copies.count
        // **"copies" is a file's word.** A folder group's members are folders, and the one kind
        // that already said so read better for it — so all of them do.
        let unit = group.isDirectory ? "folder\(n == 1 ? "" : "s")" : "cop\(n == 1 ? "y" : "ies")"
        switch group.matchType {
        case .identical:
            return group.isDirectory ? "\(n) \(unit) · identical trees" : "\(n) \(unit) · byte-for-byte"
        case .sameText:
            // Short enough to survive the header row: "same text, different bytes" measured
            // truncated to "same text, diffe…" at 640pt, so only half of it fits.
            //
            // **The half kept is the one the section does not already state**, which is also the
            // correction to what this comment used to say. It claimed the badge beside it read
            // "Same text" — `DuplicateMatchStyle.badgeLabel` returned "needs review" for every
            // exception kind, so that was untrue while the badge existed, and the badge is gone
            // now besides. What genuinely carries "reads the same" is the section's own definition
            // line, `DuplicateSections.definition(.sameText)`, directly above these cards.
            return "\(n) \(unit) · bytes differ"
        case .overlapping(let f):
            return "\(n) \(unit) · \(Int((f * 100).rounded()))% shared"
        case .versions:
            return "\(n) versions"
        }
    }

    /// An overlap reports "shared", never "reclaim": the figure must not promise a button that
    /// isn't there (merge is a separate action), and the difference lives in the verb slot so the
    /// digit column still lines up down the list.
    private var reclaimIsOverlap: Bool {
        if case .overlapping = group.matchType { return true }
        return false
    }

    /// The figure itself — approximate for an overlap, where the per-copy share is an average.
    private var reclaimFigure: String {
        (reclaimIsOverlap ? "~" : "") + FileSyncManager.formatBytes(group.reclaimableBytes)
    }

    /// The majority row's green pill lives on the number the row is about, rather than on a leading
    /// badge naming a category (ROADMAP.md, the Identical-badge item — the badge it argued against
    /// is since gone entirely). Exceptions keep plain digits: their colour budget is on the stripe.
    private var reclaimWearsPill: Bool { group.matchType.kind == .identical }

    private var reclaimInk: AnyShapeStyle {
        reclaimIsOverlap ? AnyShapeStyle(.secondary) : AnyShapeStyle(SemanticColor.success)
    }

    /// The figure as the stacked header draws it: no invisible columns, because there is no row beneath it to
    /// align with — and the verb is dropped, since a tile has no neighbouring digits to be told
    /// apart from. Every branch is the row's, read off the same four properties, so the two layouts
    /// cannot come to disagree about what this group reclaims.
    @ViewBuilder
    private var stackedReclaim: some View {
        if group.reclaimableBytes > 0 {
            if reclaimWearsPill {
                Text(reclaimFigure)
                    .scaledFont(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SemanticColor.success)
                    .pillSurface(.mini, tint: SemanticColor.success)
            } else {
                Text(reclaimFigure)
                    .scaledFont(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(reclaimInk)
            }
        } else {
            Text("nothing to reclaim")
                .scaledFont(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var reclaimColumns: some View {
        let verbWidth = DuplicateGroupColumns.verbSlotWidth(scale: appFontScale)
        let digitsWidth = DuplicateGroupColumns.digitsSlotWidth(scale: appFontScale)
        if group.reclaimableBytes > 0 {
            Text(reclaimIsOverlap ? "shared" : "reclaim")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(minWidth: verbWidth, alignment: .trailing)
            if reclaimWearsPill {
                Text(reclaimFigure)
                    .scaledFont(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SemanticColor.success)
                    .pillSurface(.mini, tint: SemanticColor.success)
                    .frame(minWidth: digitsWidth, alignment: .trailing)
            } else {
                Text(reclaimFigure)
                    .scaledFont(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(reclaimInk)
                    .frame(minWidth: digitsWidth, alignment: .trailing)
            }
        } else {
            Text("nothing to reclaim")
                .scaledFont(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(minWidth: verbWidth + 12 + digitsWidth, alignment: .trailing)
        }
    }

    // MARK: Body

    private func body(for group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(group.copies.enumerated()), id: \.element.id) { idx, copy in
                copyRow(copy)
                if idx < group.copies.count - 1 {
                    Divider().overlay(Color.primary.opacity(0.05))
                }
            }
            previewNote
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    /// One copy: its preview, its name, where it lives, and what will happen to it.
    ///
    /// **The previews used to be a band of their own above these rows**, which cost a full tile
    /// height plus a caption plus a divider, and put the picture of a copy a long way from the row
    /// describing it — on a four-copy group you matched tile 3 to row 3 by counting. Inline, the
    /// preview IS the row's picker: the thing you click to keep a copy is a picture of that copy,
    /// which is the gesture the tiles already looked like they offered.
    ///
    /// **The name gets a line of its own.** It used to be the last crumb of the breadcrumb,
    /// highlighted — so "Passport Old – Shweta – All Pages (Jul 2020) – Compressed.pdf" wrapped
    /// that cell onto two and three lines and pushed the path off the row. A name and a location
    /// are two facts; they read as two lines.
    /// **The whole row is the picker where a choice exists**, not just the preview in it.
    ///
    /// His report: "it's not obvious that only the thumbnail needs to be clicked." It was not
    /// obvious because it is not true of anything else on this screen — the header row toggles from
    /// anywhere along it, and a row that responds only in its first forty points is a target you
    /// find by accident. The thumbnail keeps its own tap and its own hover lift (it is still the
    /// thing that says *which* copy), and both call the same action, so a click that lands on
    /// either does the same thing.
    ///
    /// Gated on the one rule the radio and the thumbnail already read
    /// (``DuplicateKeeperMarker/style(allowsKeeperChoice:isKeeper:)``): the kept copy's own row and
    /// every row in a group that allows no choice stay inert, because a row that highlights under
    /// the pointer and does nothing is the same complaint one size larger.
    /// Whether clicking this row picks its copy — **a named function so the gate is reachable from
    /// a test**, which an inline condition inside a `@ViewBuilder` is not.
    ///
    /// One expression, read off the shared marker rule, so the row, the radio and the thumbnail
    /// cannot come to offer three different answers about the same copy.
    func isRowPickable(_ copy: DuplicateCopy) -> Bool {
        DuplicateKeeperMarker.style(allowsKeeperChoice: group.allowsKeeperChoice,
                                    isKeeper: copy.isRecommendedKeeper) == .selectable
    }

    /// One copy's row — **the only control in it.**
    ///
    /// The thumbnail and the radio inside are pictures of state; this is what is clicked. They
    /// were each a control of their own until the row became one, under `isRowPickable` — the
    /// same `DuplicateKeeperMarker.style(…) == .selectable` predicate that gated both — so a
    /// pickable row shipped with two hit targets, two tooltips, two hover treatments and two
    /// nested `.isButton` elements for a single action.
    ///
    /// The pointing hand is here for the same reason, and only here: it used to be pushed by the
    /// tile and by the radio, so it appeared over two small islands of a row that is clickable
    /// end to end — which is exactly the complaint that made the row clickable in the first place.
    @ViewBuilder
    private func copyRow(_ copy: DuplicateCopy) -> some View {
        if isRowPickable(copy) {
            Button(action: keeperAction(for: copy)) {
                copyRowContent(copy).contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.row, tint: hueAccent))
            .pointingHandCursor()
            // **The row owns the tooltip too, and carries the path in it.** The tile kept a
            // `.help(path)` of its own, and an inner tooltip wins over its container — so the
            // largest thing in a clickable row was the one place that did not say what clicking
            // does. One tooltip per row, and the path rides along because the breadcrumb beneath
            // truncates and omits the file name.
            .help("Keep this copy instead — \(copy.path)")
            .accessibilityHint("Keeps this copy instead")
            .contextMenu { compareWithKeeperItem(copy) }
        } else {
            // No action to describe, so the tooltip is the path alone — still on the row, so a
            // reader gets the same answer wherever they rest the pointer.
            copyRowContent(copy).help(copy.path)
                .contextMenu { compareWithKeeperItem(copy) }
        }
    }

    /// The row's secondary way in to Compare — the whole row is already a keeper-pick `Button`, so
    /// a competing click gesture on it would collide (which is why the ⌘-double-click idea was
    /// dropped). A context menu adds no gesture to the row at all.
    ///
    /// Absent on the keeper's own row: comparing the keeper with the keeper is not a thing, and a
    /// menu item that no-ops is worse than no menu.
    @ViewBuilder
    private func compareWithKeeperItem(_ copy: DuplicateCopy) -> some View {
        if !copy.isRecommendedKeeper, copy.id != group.keeper.id {
            Button("Compare with keeper") { onCompareCopies(group.keeper, copy) }
        }
    }

    private func copyRowContent(_ copy: DuplicateCopy) -> some View {
        // Centred, not top-aligned: the picker is one item against a two- or three-line text
        // block, and hanging it off the first baseline left it visibly high in the row.
        HStack(alignment: .center, spacing: 11) {
            picker(copy)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(copy.name)
                        .scaledFont(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    fateChip(copy)
                }
                folderBreadcrumb(for: copy.path)
                // The size/date detail line is the secondary text compact hides (H7); the
                // fate chip and breadcrumb still carry what happens to the copy and where it is.
                if densityMetrics.showsSecondaryDetail {
                    Text(metaLine(copy))
                        .scaledFont(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, densityMetrics.cardRowVerticalPadding)
    }

    /// What the row is picked with — a content preview for a file, the marker for a folder.
    ///
    /// A folder group has nothing to preview (the strip skipped directories for that reason: a
    /// folder icon adds no confidence), so those rows keep the radio, in a narrower slot so the
    /// text does not sit in an empty 40pt column.
    /// How many copies get a real QuickLook preview before the rest fall back to the file-type
    /// icon. **The cap the deleted thumbnail strip used to carry** — that strip rendered at most
    /// six tiles; these rows render one per copy, so without a cap a forty-copy group starts forty
    /// generations the moment it is expanded. Twelve because a group that size is already a
    /// scroll, and the tile stays the picker either way.
    static let previewsPerCard = 12

    @ViewBuilder
    private func picker(_ copy: DuplicateCopy) -> some View {
        if group.isDirectory {
            radio(copy).frame(width: 18)
        } else {
            DuplicateThumbnailView(path: copy.path,
                                   // The copy's own name, not the group's: in a versions or
                                   // same-text group they differ, and this is what the fallback
                                   // file-type icon is chosen from.
                                   name: copy.name,
                                   isKeeper: copy.isRecommendedKeeper,
                                   modified: copy.modificationDate,
                                   nonKeeperLabel: group.matchType.kind == .sameText
                                       ? "same text" : "duplicate",
                                   side: 40,
                                   showsCaption: false,
                                   loadsPreview: (group.copies.firstIndex { $0.id == copy.id } ?? 0)
                                       < Self.previewsPerCard)
        }
    }

    /// What a thumbnail does when clicked — **a named function so the wiring is reachable from a
    /// test**, which the inline closure was not.
    ///
    /// Passing `onChoose: {}` here compiles and quietly turns the tiles back into the decoration
    /// they used to be; the compiler catches a *missing* argument but not an empty one.
    ///
    /// **`theCardsThumbnailActionReachesItsHandler` calls this function, not the call site**, so it
    /// does not close that hole — replacing the argument in `picker(_:)` leaves it green. What it
    /// pins is that the action, once passed, reaches `onChooseKeeper` with the right id. The hole
    /// is stated in that test rather than implied away.
    func keeperAction(for copy: DuplicateCopy) -> () -> Void {
        { onChooseKeeper(copy.id) }
    }

    /// The keeper marker, from ``DuplicateKeeperMarker/style(allowsKeeperChoice:isKeeper:)``.
    ///
    /// A green filled radio on the kept copy and a hollow one on the others — **but only where a
    /// keeper can actually be picked**. Where none can, both rows get the plain dot, so the row
    /// never advertises a pick that isn't there. Which kinds allow one is
    /// `DuplicateGroup.allowsKeeperChoice`, and it is deliberately not restated here: the list has
    /// drifted three times, each time by being spelled out somewhere.
    ///
    /// **None of the three is a control.** `selectable` used to be its own `Button` — which, once
    /// `copyRow` became a `Button` under the very same predicate, put a button inside a button:
    /// the inner one takes the hit, the outer one never fires there, and VoiceOver reads two
    /// controls for one action. The radio shows the state and the row does the picking; it takes
    /// the accent through `hoverTint`, which reads the row button's own hover phase from the
    /// environment, so hovering ANYWHERE on the row lights the radio rather than only over it.
    @ViewBuilder
    private func radio(_ copy: DuplicateCopy) -> some View {
        switch DuplicateKeeperMarker.style(allowsKeeperChoice: group.allowsKeeperChoice,
                                      isKeeper: copy.isRecommendedKeeper) {
        case .keeper:
            Image(systemName: "largecircle.fill.circle")
                .scaledFont(.system(size: 15))
                .foregroundStyle(SemanticColor.success)
                .accessibilityLabel(DuplicateKeeperMarker.keeper.accessibilityLabel ?? "")
        case .selectable:
            Image(systemName: "circle")
                .scaledFont(.system(size: 15))
                .foregroundStyle(.secondary)
                .hoverTint(hueAccent)
                .accessibilityLabel(DuplicateKeeperMarker.selectable.accessibilityLabel ?? "")
        case .inert:
            Circle()
                .fill(.tertiary)
                .frame(width: 5, height: 5)
                .frame(width: 15)   // keep the text column aligned with the radio rows
                .accessibilityHidden(true)
        }
    }

    /// **True when "merge" would copy nothing.** Every folded copy is already wholly inside the
    /// keeper (`uniqueItemCount == 0`), so the operation is a removal wearing a merge's name.
    ///
    /// His screenshot: a `Visa` folder of one item, 100% shared, under a card offering "Merge into
    /// keeper" over a note reading "the other copy adds 0 unique items. Merging copies those into
    /// “Visa”" — copying *those*, where those is nothing. The action is unchanged (it is the same
    /// code path, and it still trashes the folded copy); what changes is that the card stops
    /// describing a copy that does not happen.
    var mergeCopiesNothing: Bool {
        group.matchType.kind == .overlapping
            && !group.redundantCopies.isEmpty
            && group.redundantCopies.allSatisfy { $0.uniqueItemCount == 0 }
    }

    private func fateChip(_ copy: DuplicateCopy) -> some View {
        Group {
            if copy.isRecommendedKeeper {
                chip("Keep", systemImage: "checkmark", color: SemanticColor.success)
            } else {
                switch group.matchType {
                case .identical, .versions, .sameText:
                    chip("Move to Trash", systemImage: "trash", color: SemanticColor.error)
                case .overlapping:
                    // A copy with nothing of its own is not folded in, it is thrown away — and
                    // the row is where a reader decides whether that is what they want.
                    if copy.isFullyRedundant {
                        chip("Move to Trash", systemImage: "trash", color: SemanticColor.error)
                    } else {
                        chip("Fold in", systemImage: "arrow.triangle.merge",
                             color: SemanticColor.warning)
                    }
                }
            }
        }
    }

    private func chip(_ text: String, systemImage: String, color: Color) -> some View {
        Pill(.mini, tint: color, systemImage: systemImage, text: text)
    }

    /// "1 unique here", not "1 unique heres" and not "1 uniques" — the count is interpolated into
    /// a noun phrase, which is where this app's plural bugs live.
    nonisolated static func uniqueHere(_ count: Int) -> String {
        "\(count) unique here"
    }

    private func metaLine(_ copy: DuplicateCopy) -> String {
        var parts: [String] = []
        if copy.isDirectory {
            parts.append("\(copy.itemCount) item\(copy.itemCount == 1 ? "" : "s")")
        }
        parts.append(FileSyncManager.formatBytes(copy.size))
        if let d = copy.modificationDate {
            parts.append("modified \(Self.dateFormatter.string(from: d))")
        }
        if !copy.isRecommendedKeeper {
            switch group.matchType {
            case .overlapping where copy.uniqueItemCount > 0:
                parts.append(Self.uniqueHere(copy.uniqueItemCount))
            case .identical, .versions:
                parts.append(copy.isFullyRedundant ? "fully redundant"
                                                   : Self.uniqueHere(copy.uniqueItemCount))
            // Deliberately NOT "fully redundant": that phrase is the content hash's promise, and
            // this group has not proved it. What it proved is in the note, and in the section's
            // definition line above the card.
            case .sameText:
                break
            default: break
            }
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var previewNote: some View {
        if let text = noteText {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle")
                    .scaledFont(.system(size: 12))
                    .foregroundStyle(SemanticColor.info)
                Text(text)
                    .scaledFont(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).fill(Color.primary.opacity(0.04)))
            .padding(.top, 10)
        }
    }

    private var noteText: String? { DuplicateGroupNote.text(for: group) }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 9) {
            if group.isFullyResolvableByRemoval {
                Button(action: onApply) {
                    Label(applyTitle, systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .chromeHover()
                .controlSize(.small)
                // Nothing to remove means the button would open no dialog and do nothing at all —
                // a dead control. Reachable by re-aiming the keeper of a group whose other copies
                // all live inside a folder another group is keeping (see `isProtectedFromRemoval`).
                .disabled(isMerging || group.recommendedRemovalPaths.isEmpty)
            } else if group.matchType.kind == .overlapping {
                Button(action: onMerge) {
                    if isMerging {
                        Label {
                            Text("Merging…")
                        } icon: {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    } else {
                        Label(mergeCopiesNothing
                                  ? (group.redundantCopies.count == 1
                                     ? "Trash the folded copy" : "Trash the folded copies")
                                  : "Merge into keeper",
                              systemImage: mergeCopiesNothing ? "trash" : "arrow.triangle.merge")
                    }
                }
                .buttonStyle(.borderedProminent)
                .chromeHover()
                .controlSize(.small)
                .disabled(isMerging)
            }
            // **Every group gets this now.** It used to be folder-only, on the grounds that a
            // file group's copies "carry a preview each, which is the same comparison in place" —
            // a 40pt thumbnail is not. A file pair opens the in-window Compare Copies surface; a
            // folder pair keeps the Compare-workspace hand-off. The card does not know which: it
            // has one closure, and the host branches on `isDirectory` (see `LensWorkspaceView`).
            compareControl
            Button(action: onReveal) {
                Label("Reveal", systemImage: RevealGlyph.inFinder)
            }
            .chromeHover()
            .controlSize(.small)
            Button(action: onKeepSeparate) {
                Label("Keep separate", systemImage: "lock")
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.segment, tint: hueAccent))
            .controlSize(.small)
            .disabled(isMerging)   // would drop the group from the list mid-merge
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var applyTitle: String {
        switch group.matchType {
        case .versions: return "Keep newest, Trash older"
        case .sameText: return group.copies.count > 2 ? "Keep one, Trash the rest" : "Trash the other copy"
        default: return group.copies.count > 2 ? "Keep one, Trash the rest" : "Trash redundant copy"
        }
    }

    /// "Compare copies": a direct button when there's a single redundant copy (a 2-copy group), or a
    /// menu to pick which redundant copy to compare against the keeper when there are more than two —
    /// Compare has exactly two panes, so bigger groups are reviewed two at a time (keeper vs each).
    ///
    /// **Both arms must LOOK the same**, because which one a group gets is decided by how many
    /// copies it happens to have — not by anything the reader chose. The menu wore
    /// `.menuStyle(.borderlessButton)`, which draws its own chrome rather than adopting the row's,
    /// so the same control was a bordered button on a two-copy group and a borderless label on a
    /// three-copy one, side by side in the same list. `.menuStyle(.button)` is the fix the pane
    /// header's sort control already uses for exactly this: a `Menu` does not inherit an ambient
    /// button style on its own.
    @ViewBuilder
    private var compareControl: some View {
        if group.redundantCopies.count <= 1 {
            Button {
                if let other = group.redundantCopies.first { onCompareCopies(group.keeper, other) }
            } label: {
                Label("Compare copies", systemImage: "rectangle.split.2x1")
            }
            .chromeHover()
            .controlSize(.small)
        } else {
            Menu {
                ForEach(group.redundantCopies) { copy in
                    Button(location(for: copy.path)) { onCompareCopies(group.keeper, copy) }
                }
            } label: {
                Label("Compare with…", systemImage: "rectangle.split.2x1")
            }
            .menuStyle(.button)
            .chromeHover()
            .fixedSize()
            .controlSize(.small)
        }
    }

    /// A short "iCloud › … › name" location for a copy, reusing the breadcrumb derivation so a
    /// many-copy menu can tell the otherwise identically-named copies apart by where they live.
    private func location(for path: String) -> String {
        crumbs(path).joined(separator: " › ")
    }

    // MARK: Breadcrumb

    /// Where the copy lives — the folder path only, on exactly one line.
    ///
    /// **This used to be an `HStack` of per-crumb `Text`s ending in the file name, chipped.** An
    /// HStack cannot truncate: each crumb is its own view, so a long name pushed the row and the
    /// stack wrapped, which is what put a three-line breadcrumb cell beside a one-line preview. One
    /// concatenated `Text` truncates as a single string, and the name is not in it at all — the row
    /// above states it, and stating it twice is what made the cell need the width in the first
    /// place.
    ///
    /// Middle truncation rather than head: the provider crumb is the one that says *which* cloud,
    /// and it is the first thing a head truncation eats.
    private func folderBreadcrumb(for path: String) -> some View {
        // The last crumb is the copy itself, named on the line above.
        let comps = Array(crumbs(path).dropLast())
        let tail = comps.dropFirst().joined(separator: " › ")
        return Group {
            if let provider = comps.first {
                Text(provider)
                    .foregroundColor(providerName != nil ? hueAccent : Color.secondary)
                    + Text(tail.isEmpty ? "" : " › \(tail)").foregroundColor(.secondary)
            } else {
                Text("")
            }
        }
        .scaledFont(.system(size: 11, design: .monospaced))
        .lineLimit(1)
        .truncationMode(.middle)
        // No `.help` here either — `copyRow` carries one tooltip for the whole row, and this is
        // its only caller. An inner tooltip wins, so leaving one on the widest element in the row
        // would shadow the row's over most of its area, which is the shape of the bug this pass
        // removed from the tile.
    }

    /// The path as crumbs, relative to the scanned root.
    ///
    /// **The root's own name is a crumb.** Stripping it silently made a folder sitting directly in
    /// the scanned directory read as `iCloud` alone — as though it lived at the top of the
    /// provider — while its neighbour six levels down read as a full path. His report: "the 2 paths
    /// aren't correctly listed; rather it's relative to selected directory to organize, but that
    /// should be indicated clearly." Naming the root turns `iCloud` into `iCloud › Immigration`,
    /// and the pair into two paths that visibly share a trunk and diverge.
    private func crumbs(_ path: String) -> [String] {
        Self.crumbs(of: path, scanRoot: scanRoot, providerName: providerName)
    }

    /// Pure, so the rule can be held to its cases — see ``DuplicateBreadcrumbTests``. The instance
    /// method above is a one-line forward; nothing pins that it is called, and a render cannot
    /// read text back.
    /// `nonisolated` because a `View`'s static members are implicitly main-actor isolated, and a
    /// pure path rule has no business being: called off the main actor it traps rather than
    /// returning, which is a crash in a test rather than a failure.
    nonisolated static func crumbs(of path: String, scanRoot: String?,
                                   providerName: String?) -> [String] {
        // Boundary-safe on "/" (same rule as FilingSuggestionCard.isPath): a scan root of
        // "/data/Docs" must not claim "/data/DocsBackup/…" and strip it to "Backup/…".
        if let root = scanRoot, path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            let rel = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var comps = rel.isEmpty ? [] : rel.components(separatedBy: "/")
            // The scanned folder itself, so "relative to" is visible rather than assumed. Skipped
            // when the root is a whole volume or home directory, whose last component ("/" or the
            // user name) names nothing the reader chose.
            let rootName = (root as NSString).lastPathComponent
            if !rootName.isEmpty, rootName != "/", rootName != NSUserName() {
                comps.insert(rootName, at: 0)
            }
            if let providerName { comps.insert(providerName, at: 0) }
            return comps
        }
        let tilde = (path as NSString).abbreviatingWithTildeInPath
        return tilde.components(separatedBy: "/").filter { !$0.isEmpty }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

// MARK: - Header layout

/// Whether a duplicates card draws its collapsed header as a full-width row or as a grid tile.
///
/// **The row is a table row; the tile is a card.** The row's six facts sit in invisible columns
/// (``DuplicateGroupColumns``) so that a figure lines up with the figures above and below it — a
/// property of a list, and one that costs 380pt of width to keep (see
/// ``DuplicateCardHeaderLayout/rowHeaderMinimumWidth``). In a grid the neighbours are beside rather
/// than above, so the alignment buys nothing that a narrow column can afford.
///
/// Which one is drawn is the pane's decision, not the card's: `LensCardGrid` decides how many
/// columns fit, and one column keeps the row that has always been drawn there.
enum DuplicateCardHeaderLayout: Equatable {
    /// One line, in the invisible columns — the dense list a single column has always been.
    case row
    /// Three short lines, the name on one of its own.
    case stacked

    /// **The narrowest card the one-line header fits in.** Measured, not asserted: below this the
    /// header draws WIDER than the card it was given rather than truncating — the icon, the
    /// subtitle, the two figure columns and the chevron are all `.fixedSize()`, and only the name
    /// can shed. `theRowHeaderOverflowsAGridColumnAndTheStackedOneDoesNot` scans for the threshold
    /// and holds this constant to it, so it cannot drift when the header gains a word.
    ///
    /// **It did NOT move when the match-type badge went, and the near miss is worth keeping.**
    /// The scan finds the width at which the header stops drawing WIDER than its card — and the
    /// name is allowed to truncate, so that width is reached with almost no room left for the
    /// name. Losing the badge dropped that bare fit from 364 to 264, the scan's old upper bound
    /// demanded the constant hug it, and following it to 280 put 370pt tiles on the one-line
    /// header — where `Passport - Shweta - All Pages.pdf` and `Passport - Abhishek - All
    /// Pages.pdf` both render as `Passpor…ages.pdf`. Not an overflow, and nothing a fit
    /// measurement can see: two different files reading as one string.
    ///
    /// So the constant is founded on the NAME's room instead — ``rowHeaderNameBudget`` past the
    /// bare fit — and 380 is what that comes to. The badge's departure is spent on the name rather
    /// than on admitting narrower cards: at this width the name now gets ~116pt where it got ~16.
    ///
    /// It was chosen by COLUMN COUNT before, which was the wrong question: one column simply meant
    /// "the pane is under 534pt", and a pane at the app's 760pt window floor gives a card near
    /// 350 — narrower than the header needs, so the row header was drawn only at widths where it
    /// does not fit and the chevron and reclaim figure were clipped at the pane edge.
    static let rowHeaderMinimumWidth: CGFloat = 380

    /// How much width the NAME must have before the one-line header is worth drawing, past the
    /// point where the row merely stops overflowing.
    ///
    /// A budget rather than a measurement, because what it protects is content-dependent: the row
    /// stays honest for `Tax 2025` at any width and truncates `Passport - Shweta - All Pages.pdf`
    /// even at 560. 100pt is where a middle-truncated document name keeps enough of both ends to
    /// tell two of them apart, which is the whole job of the name in this list.
    static let rowHeaderNameBudget: CGFloat = 100

    /// **A narrow card takes the stacked header, and so does an expanded one** — for opposite
    /// reasons that want the same shape.
    ///
    /// A narrow card has no room for the one-liner. An expanded card has plenty, and still could
    /// not show a name: the row header spends the width after the name on a subtitle and two
    /// figure columns, so "Passport Old - Shweta - All Pages (Jul 2020) - Compressed.pdf" arrived
    /// as "Passport Old - Sh…) - Compressed.pdf". His report. The facts below the title are the
    /// same facts; they just stop competing with it for the line.
    ///
    /// A COLLAPSED card with room keeps the one-liner, because there the density is the point —
    /// eighty-odd groups at three lines each is three times the scrolling, and a collapsed card's
    /// name is a thing you skim rather than read.
    static func forCard(width: CGFloat, isExpanded: Bool) -> DuplicateCardHeaderLayout {
        if isExpanded { return .stacked }
        return width >= rowHeaderMinimumWidth ? .row : .stacked
    }
}

// MARK: - The card's explanatory note

/// What the card says under the copies — one short paragraph per match kind.
///
/// **Lifted out of the view and cut to about a third of its length.** His report: "too long and
/// distracting". The same-text note ran four sentences and was the longest thing on a card whose
/// actual content is two file paths; the identical note spent a clause explaining that a Trash is
/// not a delete, in a sentence that also had to define redundancy. A note that long is read once
/// and skipped forever, which costs exactly the warnings it exists to carry.
///
/// The same-text note still names the three ways a document can read the same without being the
/// same, and still promises the undo — said once instead of twice, and without the sentence
/// explaining how providers re-stamp downloads, which is a cause the reader does not need in order
/// to decide. **Two claims did leave**, and neither is lost: "never part of Apply recommended"
/// moved to ``DuplicateRemovalPrompt/batchInformativeText``, which is the last thing read before
/// that button acts; and the note for the name-only kind went when that kind was removed.
///
/// Pure and out of the view for the reason ``DuplicateRemovalPrompt`` is: this is the text a user
/// reads immediately before a destructive click, and inline in a `body` nothing could hold it to
/// its claims — or to its length. ``DuplicateGroupNoteTests`` does both.
enum DuplicateGroupNote {

    /// The longest a base note may be — and it means something only because no note interpolates
    /// an unbounded string. The overlapping one used to name the keeper's file, which made its
    /// length a property of the data and the cap a formality.
    ///
    /// The longest a base note may be. Not a style preference: at the pane widths this card is read
    /// in, past this it stops being a caption and becomes a paragraph, which is the state he
    /// reported. The same-text note it was cut from measured 409 characters, and 534 with the
    /// unverified caveat appended.
    static let lengthBudget = 150

    static func text(for group: DuplicateGroup) -> String? {
        let base: String
        switch group.matchType {
        case .identical:
            base = "Everything in the removed \(group.isDirectory ? "copy" : "file") is in the one you keep. ⌘Z undoes it."
        case .versions:
            base = "Keeps the newest; older versions go to the Trash. ⌘Z undoes it."
        case .overlapping(let fraction):
            let unique = group.redundantCopies.reduce(0) { $0 + $1.uniqueItemCount }
            let many = group.redundantCopies.count != 1
            let pct = Int((fraction * 100).rounded())
            if unique == 0 {
                // Nothing to copy: the folded copies are already wholly inside the keeper, so
                // "merging copies those" would be describing a copy of nothing.
                base = "\(pct)% shared, and the other cop\(many ? "ies add" : "y adds") nothing the "
                    + "keeper lacks. Merging only trashes \(many ? "them" : "it"). ⌘Z undoes it."
            } else {
                // **The keeper is named on the card, not in here.** Interpolating its file name
                // made the note's length a property of the data — 164 characters against a 150
                // budget for the 61-character name this lens was redesigned around — so the cap
                // measured nothing. The row above says which copy is kept, with a "Keep" chip.
                base = "\(pct)% shared; the other cop\(many ? "ies add" : "y adds") \(unique) "
                    + "unique item\(unique == 1 ? "" : "s"), copied into the one you keep before "
                    + "the rest is trashed. ⌘Z undoes it."
            }
        case .sameText:
            base = "Reads the same, bytes differ — a signed, redacted or re-saved copy looks identical. Open both first; ⌘Z undoes it."
        }
        if let caveat = DuplicateUnverifiedNote.text(
            unverifiedCount: group.copies.filter { $0.contentUnverified }.count) {
            return base + " " + caveat
        }
        return base
    }
}

// MARK: - Unverified-content note

/// Pure wording for the card's caveat when some copies in a group could not be content-verified
/// (hash skipped: too large, cloud-only, unreadable) — the group's content claim rests on less
/// than full verification, and the note must say so before the user trusts a one-click resolve.
///
/// **It is one clause, because it is appended to a note that is already a caveat.** The long form
/// spelled out both reasons and then repeated "review before removing anything", which the
/// same-text note it most often follows had already said — and a warning read past is not a
/// warning. The reasons stay, in parentheses, because a cloud-only copy and a too-large one are
/// fixed by different things.
enum DuplicateUnverifiedNote {
    static func text(unverifiedCount count: Int) -> String? {
        guard count > 0 else { return nil }
        let plural = count != 1
        return "\(count) not content-verified (too large, or not downloaded)."
    }
}

/// The scan-level counterpart to ``DuplicateUnverifiedNote``: wording for the summary row's "skipped"
/// pill tooltip when the duplicate scan skipped candidate files during hashing entirely, spelling
/// out the per-reason split. Only reasons that actually occurred are listed, so the tooltip never
/// mentions an empty category.
enum DuplicateScanSkipNote {
    static func text(_ skips: FileSyncManager.DuplicateScanSkips) -> String? {
        guard skips.total > 0 else { return nil }
        var reasons: [String] = []
        if skips.tooLarge > 0 { reasons.append("\(skips.tooLarge) too large to hash") }
        if skips.cloudOnly > 0 { reasons.append("\(skips.cloudOnly) cloud-only (not downloaded)") }
        if skips.multiLink > 0 { reasons.append("\(skips.multiLink) hard-linked (trashing a link frees nothing)") }
        // Deliberately vague about WHICH way it failed: gone, unreadable, replaced between the
        // stat and the open, or rewritten mid-read all land here, and the scan cannot tell the
        // reader which without re-reading a file it already could not trust.
        if skips.unverifiable > 0 { reasons.append("\(skips.unverifiable) unreadable or changed while being read") }
        let plural = skips.total != 1
        var note = "\(skips.total) file\(plural ? "s" : "") outside duplicate detection: "
            + "\(reasons.joined(separator: ", ")). Duplicates among them are not detected."
        // A DIFFERENT claim being declined, so a different sentence — and deliberately not part of
        // the pill's count. These documents were hashed and grouped normally; all that was declined
        // is the weaker same-text comparison, because an image-only scan says nothing to compare.
        // Rolling them into "outside duplicate detection" would be a much larger and much less true
        // number (853 of 10,569 on the tree this was measured against).
        if skips.textUnreadable > 0 {
            let many = skips.textUnreadable != 1
            note += " A further \(skips.textUnreadable) document\(many ? "s" : "") "
                + "\(many ? "were" : "was") hashed but said too little to compare by text "
                + "(image-only scan, locked, or almost no text), so a re-downloaded copy of "
                + "\(many ? "one of them" : "it") is not detected either."
        }
        return note
    }
}

/// The wording of the per-group "Move to Trash" confirmation — the last thing the user reads
/// before a destructive action, and therefore the one place the vocabulary must not drift.
///
/// It exists because it did drift. The card is careful about a same-text group: an unfilled seal,
/// "bytes differ", a note asking the user to open the documents first, and a thumbnail caption that
/// deliberately does NOT say "duplicate". The confirmation then called the other file a *redundant
/// copy* — the identical group's word, asserting the very thing this group has not proved — at the
/// point of no return. Inline in the view it was also untestable, which is why it went unnoticed.
enum DuplicateRemovalPrompt {

    /// What the copies being removed are called. Never "redundant" unless redundancy is proven.
    static func itemWord(for kind: DuplicateMatchType.Kind, count: Int) -> String {
        let plural = count != 1
        switch kind {
        // Versions discard genuinely older, different content — say so rather than "redundant".
        case .versions: return plural ? "older versions" : "older version"
        // Proven to READ the same, not proven to BE the same.
        case .sameText: return plural ? "matching copies" : "matching copy"
        case .identical, .overlapping: return plural ? "redundant copies" : "redundant copy"
        }
    }

    /// The line under the question: what is kept, what it reclaims, and — for a claim weaker than
    /// byte-identity — what the user is actually agreeing to.
    static func informativeText(kind: DuplicateMatchType.Kind,
                                keeperName: String,
                                keeperLocation: String,
                                reclaimText: String) -> String {
        var text = "Keeps “\(keeperName)” at \(keeperLocation). Reclaims \(reclaimText)."
        if kind == .sameText {
            text += " These read the same but their bytes differ, which is weaker than a "
                + "byte-for-byte match — a signed or edited copy would read the same too."
        }
        return text + " This can be undone with ⌘Z."
    }

    // MARK: The batch dialog ("Clean up all")

    /// The question over a whole batch. Its own sentence rather than the per-group one repeated:
    /// the batch names a provider and counts *groups*, where the per-group dialog names a file and
    /// counts copies.
    ///
    /// Here for the reason `itemWord` is: this pair was composed inline in the view, where the two
    /// pluralizations below (group/groups, copy/copies) were the only untested words in the last
    /// dialog before a delete. The per-group dialog had exactly that shape when it started calling
    /// a same-text copy "redundant".
    static func batchMessageText(groupCount: Int, providerName: String?) -> String {
        "Clean up \(groupCount) group\(groupCount == 1 ? "" : "s") in \(providerName ?? "this provider")?"
    }

    /// The line under the batch question: how many copies move, what that reclaims, and the two
    /// facts that keep it honest — the weaker match kinds are NOT included in a batch, and the
    /// whole thing is undoable.
    static func batchInformativeText(copyCount: Int, reclaimText: String) -> String {
        "Moves \(copyCount) redundant cop\(copyCount == 1 ? "y" : "ies") to the Trash, reclaiming about "
            + "\(reclaimText). Only byte-identical groups are included — versions, same-text "
            + "and overlapping groups are left untouched. "
            + "Everything can be undone with ⌘Z."
    }
}

// MARK: - Keeper marker

/// Pure mapping from (does this group allow picking a keeper?, is this copy the keeper?) to the
/// marker its row shows, so inert rows never draw a radio that looks pickable.
enum DuplicateKeeperMarker: Equatable {
    /// Green filled radio — this copy is kept.
    case keeper
    /// Hollow radio, clickable — the user may keep this copy instead.
    case selectable
    /// Small tertiary dot — no keeper choice exists in this group.
    case inert

    /// **The keeper only wears a radio where a radio means something.**
    ///
    /// This read `if isKeeper { return .keeper }` first, so a group that allows no choice still
    /// drew a filled radio on its keeper — and a filled radio is a promise that an empty one
    /// exists to click. His report on a merge card: "Why is there a checkbox, especially if we
    /// can't choose among the rows?" It is not that the rows failed to respond; it is that nothing
    /// there was ever selectable, and the marker said otherwise.
    ///
    /// An overlapping group cannot re-aim its keeper — which copy is "unique" is computed from
    /// content hashes the scan does not retain — so both its rows are `.inert` now, and the fate
    /// chips ("Keep", "Move to Trash") carry what happens. That is what this type's own doc always
    /// claimed: "so the row never advertises a pick that isn't there."
    static func style(allowsKeeperChoice: Bool, isKeeper: Bool) -> DuplicateKeeperMarker {
        guard allowsKeeperChoice else { return .inert }
        return isKeeper ? .keeper : .selectable
    }

    /// VoiceOver label; nil when the marker carries no information beyond the row itself.
    var accessibilityLabel: String? {
        switch self {
        case .keeper: return "Kept copy"
        case .selectable: return "Keep this copy"
        case .inert: return nil
        }
    }
}

/// Pure decision for hover-driven NSCursor bookkeeping. The cursor stack is global, so the
/// invariant is: push exactly once when hovering begins, pop exactly once when it ends, and
/// ignore repeated same-state callbacks — SwiftUI can deliver `onHover(true)` twice without an
/// intervening `false` when layout shifts under the pointer.
enum HoverCursorTransition: Equatable {
    case push, pop, none

    static func decide(wasHovering: Bool, isNowInside: Bool) -> HoverCursorTransition {
        switch (wasHovering, isNowInside) {
        case (false, true): return .push
        case (true, false): return .pop
        default: return .none
        }
    }
}

/// A pointing hand over this view while the pointer is inside it, on `HoverCursorTransition`'s
/// terms — **one implementation, where there were two.**
///
/// The tile and the keeper radio each hand-rolled this, so the hand appeared over two small islands
/// of a copy row that is clickable end to end. Both are pictures of state now and the row is the
/// control, so the cursor belongs to the row; a modifier is what lets it move there without a
/// third copy of the push/pop bookkeeping.
///
/// **`pushedCursor` tracks what THIS view pushed, not whether it is hovered.** The two come apart:
/// the pop used to be guarded on the same condition as the push, and a click that changed that
/// condition — picking a keeper flips the row out of `selectable` — skipped the pop and stranded a
/// pointing hand on a global stack for the session, one more per pick. Recording the push makes
/// the pop unconditional on anything that can change underneath it.
private struct PointingHandCursor: ViewModifier {
    @State private var pushedCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                switch HoverCursorTransition.decide(wasHovering: pushedCursor, isNowInside: inside) {
                case .push: NSCursor.pointingHand.push(); pushedCursor = true
                case .pop: NSCursor.pop(); pushedCursor = false
                case .none: break
                }
            }
            // A row in a LazyVStack is torn down by scrolling, by a section folding, by a filter and
            // by its own group being resolved — none of which delivers `onHover(false)`.
            .onDisappear {
                if pushedCursor { NSCursor.pop(); pushedCursor = false }
            }
    }
}

extension View {
    /// See ``PointingHandCursor``.
    func pointingHandCursor() -> some View { modifier(PointingHandCursor()) }
}
