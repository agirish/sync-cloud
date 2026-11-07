import SwiftUI
import Sync
import Design

/// One duplicate group as an expandable card: the common name, a reclaim figure and, when expanded,
/// each copy with its location, the recommended keeper and the resolve actions. The match type is
/// named by the section the card sits in, not on the card.
struct DuplicateGroupCard: View {
    let group: DuplicateGroup
    let isExpanded: Bool
    let providerName: String?
    let scanRoot: String?
    /// Row measurements for the appearance density setting, injected by the owner
    /// (`LensWorkspaceView` reads the @AppStorage once and passes the resolved metrics down).
    let densityMetrics: ListDensityMetrics
    /// The zone the meta line's "modified" date reads in: `.current` everywhere in the app.
    ///
    /// Injectable only so this card's snapshot references don't bake in the recording machine's
    /// zone, as with `LogEntryRow.timeZone`: a reference recorded in one zone goes red in another
    /// once the shift crosses a calendar day, which looks like an unrelated regression.
    var timeZone: TimeZone = .current
    let onToggle: () -> Void
    let onApply: () -> Void
    let onReveal: () -> Void
    let onKeepSeparate: () -> Void
    let onChooseKeeper: (String) -> Void
    let onMerge: () -> Void
    /// Opens two copies of this group side by side in Compare: the keeper on the left (kept), the
    /// chosen redundant copy on the right (the delete candidate). `var` with a default so existing
    /// call sites and tests can leave it out.
    var onCompareCopies: (DuplicateCopy, DuplicateCopy) -> Void = { _, _ in }
    /// True while this group's merge is in flight (`FileSyncManager.mergingGroupIDs`): the merge
    /// button becomes an inert "Merging…" indicator and the card's destructive actions disable,
    /// since a second click mid-merge would re-plan against the half-merged keeper and mint " 2"
    /// copies. `var` with a default so existing call sites and tests are unaffected.
    var isMerging: Bool = false
    /// Hands one copy's path to the Edit workspace: the app's `handOffToEditor`, the same act as
    /// the pane row's "Open in Edit". nil withholds the item, so a host with no editor (a preview,
    /// a test) offers nothing rather than an item that does nothing.
    ///
    /// No default, as with `headerLayout`: defaulted to nil, deleting the argument in
    /// `LensWorkspaceView` would compile, drop the item from every duplicate row and leave every
    /// suite green. Declared just above `headerLayout`, so the argument sits where every call site
    /// already writes something.
    let onOpenInEditor: ((String) -> Void)?
    /// How the header lays itself out; see ``DuplicateCardHeaderLayout``.
    ///
    /// No default: defaulted to `.row`, deleting the `headerLayout:` argument in
    /// `LensWorkspaceView` would compile and return every grid tile to the one-line header, which
    /// `theRowHeaderOverflowsAGridColumnAndTheStackedOneDoesNot` proves doesn't fit a grid column.
    /// The compiler holds the wiring instead.
    let headerLayout: DuplicateCardHeaderLayout

    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    /// For the invisible-column slot widths (`DuplicateGroupColumns`), measured at the live scale.
    @Environment(\.appFontScale) private var appFontScale

    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }

    /// The exception treatment's colour, or nil for the majority case, which wears no stripe and no
    /// wash. On a real scan `identical` is the overwhelming majority, and rows needing a human
    /// decision get lost if every row has the same weight, so a row's visual weight tracks how much
    /// attention it deserves. `badgeLabel` serves as the predicate because it is exactly "is this
    /// an exception kind"; no badge is drawn, since the section heading already names the kind.
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
        // The faint wash, over the card rather than under it, because `lensCard`'s own fill would
        // hide a background. 0.035 tints the whole card, not any text; the stripe carries the
        // meaning, and the section heading the word.
        .overlay {
            if let severity {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(severity.opacity(0.035))
                    .allowsHitTesting(false)
            }
        }
        // The severity stripe: inset rather than corner-flush, so it never fights the card radius,
        // and non-interactive so the header's whole-row button keeps its target.
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
        .help(isExpanded ? "Collapse this group" : "Expand this group to see its copies")
    }

    /// The full-width header: everything on one line, in the invisible columns
    /// (`DuplicateGroupColumns`). The subtitle right-aligns against the verb column; verb and
    /// digits each hold their own slot, so "reclaim 157 KB" and "~24.2 MB shared" share one digit
    /// column instead of two ragged endings. Names begin at the icon, the same x on every card,
    /// since nothing comes before it.
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
    /// A one-line header stops overflowing at 264pt and isn't worth drawing until 380: a digits
    /// column and a chevron, of which only the name can shed. Held to those numbers by
    /// `theRowHeaderOverflowsAGridColumnAndTheStackedOneDoesNot`. Below 264 the header draws wider
    /// than its card rather than truncating. The gap from 264 to 380 is `rowHeaderNameBudget`: at
    /// the bare fit the name has truncated to nothing, and only the readable width matters.
    ///
    /// Stacked, the same content reads at 220pt: the figure takes the top line, the name the card's
    /// width, and the subtitle sits under it with the chevron. No invisible columns: they align a
    /// figure with the rows above and below, a property of a table, not of a grid of tiles.
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

    /// The card is titled with the copy being kept, not the group's name.
    ///
    /// The two match whenever the copies share a name, which is most groups, but not where the pick
    /// is a real decision: a versions group holds differently named files by definition, and a
    /// same-text group often holds `Passport.pdf` beside `Passport (Jul 2020).pdf`. Titled by the
    /// group's name, picking the archived copy would leave the card headed by the file about to be
    /// trashed.
    ///
    /// Falls back to the group name rather than reading ``DuplicateGroup/keeper``, which traps on a
    /// group with no copies.
    private var titleName: String {
        group.copies.first(where: { $0.isRecommendedKeeper })?.name ?? group.name
    }

    private var fileIcon: some View {
        // The shared medium vocabulary (`FileTypeGlyph`), not NSWorkspace's raster icon: Storage
        // and Duplicates draw one file the same way, and a 17pt shape reads as "document / photo /
        // audio" where a shrunken thumbnail reads as "rectangle".
        FileTypeGlyph.view(name: group.name, isDirectory: group.isDirectory, pointSize: 14)
            .frame(width: 17, height: 17)
    }

    /// "copies" is a file's word: a folder group's members are folders, so they are counted as
    /// folders. Shared with the Overview's Duplicates examples.
    nonisolated static func memberCount(_ n: Int, isDirectory: Bool) -> String {
        isDirectory ? "\(n) folder\(n == 1 ? "" : "s")" : "\(n) cop\(n == 1 ? "y" : "ies")"
    }

    /// A group's members as the card's subtitle counts them: versions for a version group (they
    /// differ, so they aren't copies), and `memberCount`'s folders or copies otherwise. The
    /// Overview's Duplicates line reads this too, so it can't say "3 copies" over a card that says
    /// "3 versions".
    nonisolated static func memberCount(_ n: Int, isDirectory: Bool, matchType: DuplicateMatchType) -> String {
        if case .versions = matchType { return "\(n) version\(n == 1 ? "" : "s")" }
        return memberCount(n, isDirectory: isDirectory)
    }

    private var subtitle: String {
        let n = group.copies.count
        let members = Self.memberCount(n, isDirectory: group.isDirectory)
        switch group.matchType {
        case .identical:
            return group.isDirectory ? "\(members) · identical trees" : "\(members) · byte-for-byte"
        case .sameText:
            // Short enough to survive the header row: "same text, different bytes" truncates at
            // 640pt. The half kept is the one the section doesn't already state: "reads the same"
            // is the section's definition line, `DuplicateSections.definition(.sameText)`, right
            // above these cards.
            return "\(members) · bytes differ"
        case .overlapping(let f):
            return "\(members) · \(Int((f * 100).rounded()))% shared"
        case .versions:
            return Self.memberCount(n, isDirectory: group.isDirectory, matchType: group.matchType)
        }
    }

    /// An overlap reports "shared", never "reclaim": the figure must not promise a button that
    /// isn't there (merge is a separate action), and the difference lives in the verb slot so the
    /// digit column still lines up down the list.
    private var reclaimIsOverlap: Bool {
        if case .overlapping = group.matchType { return true }
        return false
    }

    /// The figure itself: approximate for an overlap, where the per-copy share is an average.
    private var reclaimFigure: String {
        (reclaimIsOverlap ? "~" : "") + FileSyncManager.formatBytes(group.reclaimableBytes)
    }

    /// The majority row's green pill sits on the number the row is about, not on a badge naming a
    /// category. Exceptions keep plain digits: their colour budget is on the stripe.
    private var reclaimWearsPill: Bool { group.matchType.kind == .identical }

    private var reclaimInk: AnyShapeStyle {
        reclaimIsOverlap ? AnyShapeStyle(.secondary) : AnyShapeStyle(SemanticColor.success)
    }

    /// The figure as the stacked header draws it: no invisible columns, since there is no row
    /// beneath to align with, and no verb, since a tile has no neighbouring digits to tell apart.
    /// Every branch reads the row's same four properties, so the two layouts can't disagree about
    /// what this group reclaims.
    @ViewBuilder
    private var stackedReclaim: some View {
        if group.reclaimableBytes > 0 {
            if reclaimWearsPill {
                Text(reclaimFigure)
                    .scaledFont(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
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
                    .foregroundStyle(.primary)
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

    /// Whether clicking this row picks its copy. A named function so the gate is reachable from a
    /// test, which an inline condition inside a `@ViewBuilder` isn't.
    ///
    /// The whole row is the picker where a choice exists, as the header toggles from anywhere along
    /// it; a row that answered only on its preview would be a target found by accident. Read off
    /// the shared marker rule (``DuplicateKeeperMarker/style(allowsKeeperChoice:isKeeper:)``), so
    /// the row and the radio can't disagree: the kept copy's row and every row in a group with no
    /// choice stay inert, since a row that highlights under the pointer and does nothing is worse.
    func isRowPickable(_ copy: DuplicateCopy) -> Bool {
        DuplicateKeeperMarker.style(allowsKeeperChoice: group.allowsKeeperChoice,
                                    isKeeper: copy.isRecommendedKeeper) == .selectable
    }

    /// One copy's row, and the only control in it.
    ///
    /// The thumbnail and the radio inside are pictures of state; the row is what is clicked. A
    /// control of their own inside this `Button` would add a second hit target, tooltip, hover
    /// treatment and nested `.isButton` for one action. The pointing hand is here for the same
    /// reason, so it shows over the whole clickable row rather than two small islands of it.
    @ViewBuilder
    private func copyRow(_ copy: DuplicateCopy) -> some View {
        if isRowPickable(copy) {
            Button(action: keeperAction(for: copy)) {
                copyRowContent(copy).contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.row, tint: hueAccent))
            .pointingHandCursor()
            // The row owns the tooltip, with the path in it: an inner tooltip wins over its
            // container, so one per row, and the path rides along because the breadcrumb truncates
            // and omits the name.
            .help("Keep this copy instead — \(copy.path)")
            .accessibilityHint("Keeps this copy instead")
            .modifier(RowMenu(isAttached: hasRowMenu(copy)) { rowMenu(copy) })
        } else {
            // No action to describe, so the tooltip is the path alone, still on the row so it
            // answers wherever the pointer rests.
            //
            // The shape is the whole row, as in the pickable branch; without it only the row's ink
            // takes a right-click, and the gap between the name and the fate chip would have no
            // menu.
            copyRowContent(copy).contentShape(Rectangle()).help(copy.path)
                .modifier(RowMenu(isAttached: hasRowMenu(copy)) { rowMenu(copy) })
        }
    }

    /// The row's context menu. The whole row is already a keeper-pick `Button`, so a competing
    /// click gesture would collide; a context menu adds nothing to the row's own click, so both
    /// items live here and nowhere else on the row.
    ///
    /// Open in Edit first, as in the pane row's single-file menu: it means the same thing on every
    /// row, keeper included. Compare with Keeper follows, only on rows where it means something.
    /// Internal, not private, so a test can host it and read what is drawn and in what order, like
    /// `keeperAction(for:)`.
    @ViewBuilder
    func rowMenu(_ copy: DuplicateCopy) -> some View {
        if offersOpenInEditor(copy) {
            Button(action: openInEditorAction(for: copy)) {
                // The same label and glyph as Edit's other entry points: one verb, one name.
                Label("Open in Edit", systemImage: "square.and.pencil")
            }
        }
        if offersCompareWithKeeper(copy) {
            Button("Compare with Keeper") { onCompareCopies(group.keeper, copy) }
        }
    }

    /// Whether this copy's row offers "Open in Edit".
    ///
    /// On every row, the keeper's included: the copy you keep is the one you most likely want to
    /// open. Gated on the same predicate the Info inspector and File ▸ Open in Edit ask
    /// (`EditableText.opensInEdit`: text, and PDFs read-only), so this row can't offer what the
    /// pane row's menu doesn't. A folder group never offers it, whatever its copies are named: a
    /// folder called `notes.md` isn't a document. Cloud-only copies are offered, as the pane row
    /// offers them; the editor's own load says what it can read.
    func offersOpenInEditor(_ copy: DuplicateCopy) -> Bool {
        onOpenInEditor != nil && !group.isDirectory && !copy.isDirectory
            && EditableText.opensInEdit(path: copy.path)
    }

    /// Whether this copy's row offers "Compare with Keeper". Absent on the keeper's own row:
    /// comparing the keeper with itself means nothing, and a menu item that does nothing is worse
    /// than none.
    func offersCompareWithKeeper(_ copy: DuplicateCopy) -> Bool {
        !copy.isRecommendedKeeper && copy.id != group.keeper.id
    }

    /// Whether the row gets a context menu at all. Not attached when it would be empty: what
    /// SwiftUI makes of an empty builder (nothing on macOS 27, where the hosting view's
    /// `menu(for:)` answers nil) is its behaviour, not this card's decision, and an empty `NSMenu`
    /// or a swallowed right-click is the cost wherever it differs. The case with no items (a
    /// non-text keeper) is decided here instead.
    func hasRowMenu(_ copy: DuplicateCopy) -> Bool {
        offersOpenInEditor(copy) || offersCompareWithKeeper(copy)
    }

    /// The "Open in Edit" item's action, named so what it hands over (the copy's path, to the
    /// card's hand-off) is reachable from a test rather than written inline in a menu nothing can
    /// click.
    func openInEditorAction(for copy: DuplicateCopy) -> () -> Void {
        { onOpenInEditor?(copy.path) }
    }

    private func copyRowContent(_ copy: DuplicateCopy) -> some View {
        // Centred, not top-aligned: the picker is one item against a two- or three-line text block,
        // and hung off the first baseline it sits visibly high.
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
                // The size and date line is the secondary text compact density hides; the fate chip
                // and breadcrumb still say what happens to the copy and where it is.
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

    /// How many copies get a real QuickLook preview before the rest fall back to the file-type
    /// icon. Rows render one per copy, so without a cap a forty-copy group would start forty
    /// generations on expand. Twelve because a group that size is already a scroll.
    static let previewsPerCard = 12

    /// What the row shows as its picker: a content preview for a file, the marker for a folder. A
    /// folder has nothing to preview, so its rows keep the radio, in a narrower slot so the text
    /// doesn't sit beside an empty 40pt column.
    @ViewBuilder
    private func picker(_ copy: DuplicateCopy) -> some View {
        if group.isDirectory {
            radio(copy).frame(width: 18)
        } else {
            DuplicateThumbnailView(path: copy.path,
                                   // The copy's own name, not the group's: in a versions or
                                   // same-text group they differ, and the fallback file-type icon
                                   // is chosen from it.
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

    /// What picking this copy does: the row's button action. A named function so the wiring is
    /// reachable from a test; `copyRow` passes it directly, so the test calls the same closure the
    /// row does.
    func keeperAction(for copy: DuplicateCopy) -> () -> Void {
        { onChooseKeeper(copy.id) }
    }

    /// The keeper marker, from ``DuplicateKeeperMarker/style(allowsKeeperChoice:isKeeper:)``.
    ///
    /// A green filled radio on the kept copy and a hollow one on the others, but only where a
    /// keeper can be picked; where none can, every row gets the plain dot, so no row advertises a
    /// pick that isn't there. Which kinds allow one is `DuplicateGroup.allowsKeeperChoice`, never
    /// restated here.
    ///
    /// None of the three is a control: a `Button` inside `copyRow`'s `Button` would take the hit
    /// itself, leave the outer one dead there, and read as two controls to VoiceOver. The radio
    /// shows state and takes the accent through `hoverTint`, which reads the row button's hover
    /// phase from the environment, so hovering anywhere on the row lights it.
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

    /// True when "merge" would copy nothing: every folded copy is already wholly inside the keeper
    /// (`uniqueItemCount == 0`), so the operation is a removal under a merge's name. The action is
    /// the same code path (it still trashes the folded copy); the card just stops describing a copy
    /// that doesn't happen.
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
                    // A copy with nothing of its own isn't folded in, it is thrown away, and the
                    // row is where a reader decides whether that is what they want.
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

    /// "1 unique here", not "1 unique heres" or "1 uniques": the count goes into a noun phrase,
    /// where plural mistakes hide.
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
            parts.append("modified \(Self.dateFormatter.string(from: d, in: timeZone))")
        }
        if !copy.isRecommendedKeeper {
            switch group.matchType {
            case .overlapping where copy.uniqueItemCount > 0:
                parts.append(Self.uniqueHere(copy.uniqueItemCount))
            case .identical, .versions:
                parts.append(copy.isFullyRedundant ? "fully redundant"
                                                   : Self.uniqueHere(copy.uniqueItemCount))
            // Not "fully redundant": that phrase is the content hash's promise, which this group
            // hasn't made. What it proved is in the note, and in the section's definition line
            // above the card.
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
                .accentedProminent()
                .chromeHover()
                .controlSize(.small)
                // With nothing to remove the button would open no dialog and do nothing. Reachable
                // by re-aiming the keeper of a group whose other copies all live inside a folder
                // another group is keeping (see `isProtectedFromRemoval`).
                .disabled(isMerging || group.recommendedRemovalPaths.isEmpty)
                .lockedDuringRun()
                .help(applyHelp)
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
                                     ? "Trash the Folded Copy" : "Trash the Folded Copies")
                                  : "Merge into Keeper",
                              systemImage: mergeCopiesNothing ? "trash" : "arrow.triangle.merge")
                    }
                }
                .buttonStyle(.borderedProminent)
                .accentedProminent()
                .chromeHover()
                .controlSize(.small)
                .disabled(isMerging)
                .lockedDuringRun()
                .help(mergeHelp)
            }
            // Every group gets this: a 40pt thumbnail is no comparison. A file pair opens the
            // in-window Compare Copies surface; a folder pair keeps the Compare-workspace hand-off.
            // The card has one closure, and the host branches on `isDirectory` (see
            // `LensWorkspaceView`).
            compareControl
            Button(action: onReveal) {
                Label("Reveal", systemImage: RevealGlyph.inFinder)
            }
            .chromeHover()
            .controlSize(.small)
            Button(action: onKeepSeparate) {
                Label("Keep Separate", systemImage: "lock")
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hoverAffordance(.segment, tint: hueAccent))
            .controlSize(.small)
            .help("Drop this group from the list and stop flagging these copies in future scans")
            .disabled(isMerging)   // would drop the group from the list mid-merge
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var applyHelp: String {
        let count = group.recommendedRemovalPaths.count
        let itemWord = DuplicateRemovalPrompt.itemWord(for: group.matchType.kind, count: count)
        return "Move \(count) \(itemWord) to the Trash and keep the one marked Keep — asks first"
    }

    private var mergeHelp: String {
        let copies = group.redundantCopies.count == 1 ? "copy" : "copies"
        return mergeCopiesNothing
            ? "Move the folded \(copies) to the Trash — the keeper already has everything in them; asks first"
            : "Copy what the keeper lacks into it, then move the folded \(copies) to the Trash — asks first"
    }

    private var applyTitle: String {
        switch group.matchType {
        case .versions: return "Keep Newest, Trash Older"
        case .sameText: return group.copies.count > 2 ? "Keep One, Trash the Rest" : "Trash the Other Copy"
        default: return group.copies.count > 2 ? "Keep One, Trash the Rest" : "Trash Redundant Copy"
        }
    }

    /// "Compare copies": a direct button for a single redundant copy (a 2-copy group), or a menu to
    /// pick which redundant copy to compare against the keeper when there are more. Compare has two
    /// panes, so bigger groups are reviewed two at a time, keeper against each.
    ///
    /// Both arms must look the same, because which one a group gets depends on its copy count, not
    /// on anything the reader chose. `.menuStyle(.button)`, as the pane header's sort control uses,
    /// because a `Menu` doesn't inherit an ambient button style and `.borderlessButton` would draw
    /// a borderless label beside bordered buttons.
    @ViewBuilder
    private var compareControl: some View {
        if group.redundantCopies.count <= 1 {
            Button {
                if let other = group.redundantCopies.first { onCompareCopies(group.keeper, other) }
            } label: {
                Label("Compare Copies", systemImage: "rectangle.split.2x1")
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

    /// A short "iCloud › … › name" location for a copy, from the breadcrumb derivation, so a
    /// many-copy menu can tell identically named copies apart by where they live.
    private func location(for path: String) -> String {
        crumbs(path).joined(separator: " › ")
    }

    // MARK: Breadcrumb

    /// Where the copy lives: the folder path only, on exactly one line.
    ///
    /// One concatenated `Text`, because an `HStack` of per-crumb texts can't truncate and wraps
    /// instead. The name isn't in it: the row above states it. Middle truncation rather than head,
    /// because the provider crumb says which cloud, and head truncation eats it first.
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
        // No `.help` here either: `copyRow` carries one tooltip for the whole row, and an inner
        // tooltip would shadow it over most of the row.
    }

    /// The path as crumbs, relative to the scanned root.
    ///
    /// The root's own name is a crumb, so "relative to" is visible: without it a folder directly in
    /// the scanned directory would read as `iCloud` alone, as though at the top of the provider,
    /// beside a neighbour six levels down with a full path. Naming the root makes them `iCloud ›
    /// Immigration` and a path that visibly shares that trunk.
    private func crumbs(_ path: String) -> [String] {
        Self.crumbs(of: path, scanRoot: scanRoot, providerName: providerName)
    }

    /// Pure, so the rule can be held to its cases; see ``DuplicateBreadcrumbTests``. `nonisolated`
    /// because a `View`'s static members are implicitly main-actor isolated, and called off the
    /// main actor this pure rule would trap rather than return.
    nonisolated static func crumbs(of path: String, scanRoot: String?,
                                   providerName: String?) -> [String] {
        // Boundary-safe on "/" (as in `FilingSuggestionCard.isPath`): a scan root of "/data/Docs"
        // must not claim "/data/DocsBackup/…" and strip it to "Backup/…".
        if let root = scanRoot, path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            let rel = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var comps = rel.isEmpty ? [] : rel.components(separatedBy: "/")
            // The scanned folder itself, so "relative to" is visible rather than assumed. Skipped
            // when the root is a whole volume or the home directory, whose last component ("/" or
            // the user name) names nothing the reader chose.
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

    private static let dateFormatter = ZoneRefreshedFormatter.localized(date: .medium, time: .none)
}

// MARK: - Header layout

/// Whether a duplicates card draws its collapsed header as a full-width row or as a grid tile.
///
/// The row is a table row; the tile is a card. The row's six facts sit in invisible columns
/// (``DuplicateGroupColumns``) so a figure lines up with those above and below it, a property of a
/// list that costs 380pt of width (``DuplicateCardHeaderLayout/rowHeaderMinimumWidth``). In a grid
/// the neighbours are beside, not above, so the alignment buys nothing. Chosen from the card's
/// width by ``forCard(width:isExpanded:)``, which the pane calls.
enum DuplicateCardHeaderLayout: Equatable {
    /// One line, in the invisible columns: the dense list.
    case row
    /// Three short lines, the name on one of its own.
    case stacked

    /// The narrowest card the one-line header is drawn in. Below the bare fit the header draws
    /// wider than its card rather than truncating: the icon, subtitle, two figure columns and
    /// chevron are all `.fixedSize()`, and only the name can shed.
    /// `theRowHeaderOverflowsAGridColumnAndTheStackedOneDoesNot` scans for that threshold and holds
    /// this constant to it, so it can't drift when the header gains a word.
    ///
    /// Founded on the name's room, not the bare fit: at the bare fit (about 264pt) the name has
    /// truncated to almost nothing, and `Passport - Mother - All Pages.pdf` and `Passport - Father
    /// - All Pages.pdf` would both read `Passpor…ages.pdf`, two files as one string, which no
    /// overflow measurement can see. So it is the bare fit plus ``rowHeaderNameBudget``.
    ///
    /// Chosen by width, not column count: a one-column pane at the app's 760pt window floor gives a
    /// card near 350, narrower than the header needs.
    static let rowHeaderMinimumWidth: CGFloat = 380

    /// How much width the name must have before the one-line header is worth drawing, past the
    /// point where the row merely stops overflowing.
    ///
    /// A budget, not a measurement, because what it protects depends on content: `Tax 2025` reads
    /// at any width and `Passport - Mother - All Pages.pdf` truncates even at 560. 100pt is where a
    /// middle-truncated document name keeps enough of both ends to tell two apart.
    static let rowHeaderNameBudget: CGFloat = 100

    /// A narrow card takes the stacked header, and so does an expanded one, for opposite reasons
    /// that want the same shape.
    ///
    /// A narrow card has no room for the one-liner. An expanded card has room but still can't show
    /// a long name: the row header spends the width after it on a subtitle and two figure columns,
    /// so "Passport Old - Mother - All Pages (Jul 2020) - Compressed.pdf" would arrive as "Passport
    /// Old - Sh…) - Compressed.pdf". Stacked, those facts stop competing with the title.
    ///
    /// A collapsed card with room keeps the one-liner: there density is the point, since eighty-odd
    /// groups at three lines each triples the scrolling, and a collapsed card's name is skimmed.
    static func forCard(width: CGFloat, isExpanded: Bool) -> DuplicateCardHeaderLayout {
        if isExpanded { return .stacked }
        return width >= rowHeaderMinimumWidth ? .row : .stacked
    }
}

// MARK: - The card's explanatory note

/// What the card says under the copies: one short paragraph per match kind.
///
/// Short, because a long note is read once and skipped forever, losing exactly the warnings it
/// carries. The same-text note names the ways a document can read the same without being the same,
/// and promises the undo once. "Never part of Apply recommended" lives in
/// ``DuplicateRemovalPrompt/batchInformativeText(copyCount:reclaimText:)``, the last thing read
/// before that button acts.
///
/// Pure and out of the view, like ``DuplicateRemovalPrompt``: this is text a user reads right
/// before a destructive click, and inline in a `body` nothing could hold it to its claims or its
/// length. ``DuplicateGroupNoteTests`` does both.
enum DuplicateGroupNote {

    /// The longest a base note may be. At the pane widths this card is read in, past this it stops
    /// being a caption and becomes a paragraph. It means something only because no note
    /// interpolates an unbounded string.
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
                // "merging copies those" would describe a copy of nothing.
                base = "\(pct)% shared, and the other cop\(many ? "ies add" : "y adds") nothing the "
                    + "keeper lacks. Merging only trashes \(many ? "them" : "it"). ⌘Z undoes it."
            } else {
                // The keeper is named on the card, not here: interpolating its file name would make
                // the note's length depend on the data and the cap meaningless. The row above marks
                // the kept copy with a "Keep" chip.
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

/// Pure wording for the card's caveat when some copies in a group couldn't be content-verified
/// (hash skipped: cloud-only, unreadable, or never needed, such as a file with no same-size twin or
/// a large one whose ends matched no twin's). The group's content claim then rests on less than
/// full verification, and the note must say so before the user trusts a one-click resolve.
///
/// One clause, because it is appended to a note that is already a caveat, and a warning repeated is
/// a warning read past. The reasons stay, in parentheses, because a cloud-only copy and an
/// unreadable one are fixed by different things.
enum DuplicateUnverifiedNote {
    static func text(unverifiedCount count: Int) -> String? {
        guard count > 0 else { return nil }
        let plural = count != 1
        return "\(count) not content-verified (not downloaded, unreadable, or not hashed)."
    }
}

/// The scan-level counterpart to ``DuplicateUnverifiedNote``: the summary row's "skipped" pill
/// tooltip when the duplicate scan skipped candidate files during hashing, split by reason. Only
/// reasons that occurred are listed, so the tooltip never mentions an empty category.
enum DuplicateScanSkipNote {
    static func text(_ skips: FileSyncManager.DuplicateScanSkips) -> String? {
        guard skips.total > 0 else { return nil }
        var reasons: [String] = []
        if skips.cloudOnly > 0 { reasons.append("\(skips.cloudOnly) cloud-only (not downloaded)") }
        if skips.multiLink > 0 { reasons.append("\(skips.multiLink) hard-linked (trashing a link frees nothing)") }
        // Vague about which way it failed on purpose: gone, unreadable, replaced between the stat
        // and the open, or rewritten mid-read all land here, and the scan can't tell which without
        // re-reading a file it already couldn't trust.
        if skips.unverifiable > 0 { reasons.append("\(skips.unverifiable) unreadable or changed while being read") }
        let plural = skips.total != 1
        var note = "\(skips.total) file\(plural ? "s" : "") outside duplicate detection: "
            + "\(reasons.joined(separator: ", ")). Duplicates among them are not detected."
        // A different claim, so a different sentence, and not part of the pill's count. These
        // documents were hashed and grouped normally; only the weaker same-text comparison was
        // declined, because an image-only scan has no text to compare. Counting them as "outside
        // duplicate detection" would give a much larger and much less true number.
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

/// The wording of the per-group "Move to Trash" confirmation: the last thing the user reads before
/// a destructive action, so the one place the vocabulary must not drift.
///
/// The card is careful about a same-text group (an unfilled seal, "bytes differ", a note asking to
/// open both first, a caption that doesn't say "duplicate"); calling the other file a "redundant
/// copy" here would assert what the group hasn't proved, at the point of no return. Pure, so tests
/// hold it to that.
enum DuplicateRemovalPrompt {

    /// What the copies being removed are called. Never "redundant" unless redundancy is proven.
    static func itemWord(for kind: DuplicateMatchType.Kind, count: Int) -> String {
        let plural = count != 1
        switch kind {
        // Versions discard older, different content: say so rather than "redundant".
        case .versions: return plural ? "older versions" : "older version"
        // Proven to read the same, not proven to be the same.
        case .sameText: return plural ? "matching copies" : "matching copy"
        case .identical, .overlapping: return plural ? "redundant copies" : "redundant copy"
        }
    }

    /// The line under the question: what is kept, what it reclaims, and, for a claim weaker than
    /// byte identity, what the user is actually agreeing to.
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

    /// The question over a whole batch. Its own sentence rather than the per-group one: the batch
    /// names a provider and counts groups, where the per-group dialog names a file and counts
    /// copies. Here, like `itemWord`, so its plurals (group/groups) are tested like the rest of the
    /// dialog's words.
    static func batchMessageText(groupCount: Int, providerName: String?) -> String {
        "Clean up \(groupCount) group\(groupCount == 1 ? "" : "s") in \(providerName ?? "this provider")?"
    }

    /// The line under the batch question: how many copies move, what that reclaims, and the two
    /// facts that keep it honest: the weaker match kinds aren't included in a batch, and it is all
    /// undoable.
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
    /// Green filled radio: this copy is kept.
    case keeper
    /// Hollow radio: the user may keep this copy instead, by clicking the row.
    case selectable
    /// Small tertiary dot: no keeper choice exists in this group.
    case inert

    /// The keeper wears a radio only where a radio means something: a filled radio promises an
    /// empty one to click, so a group that allows no choice shows `.inert` on every row, keeper
    /// included.
    ///
    /// An overlapping group can't re-aim its keeper (which copy is "unique" is computed from
    /// content hashes the scan doesn't keep), so both its rows are `.inert`, and the fate chips
    /// ("Keep", "Move to Trash") say what happens.
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

/// Pure decision for hover-driven NSCursor bookkeeping. The cursor stack is global, so: push
/// exactly once when hovering begins, pop exactly once when it ends, and ignore repeated same-state
/// callbacks, since SwiftUI can deliver `onHover(true)` twice without a `false` between when layout
/// shifts under the pointer.
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
/// terms. One implementation, used by the copy row, which is the control.
///
/// `pushedCursor` tracks what this view pushed, not whether it is hovered. If the pop were guarded
/// on the same condition as the push, a click that changed that condition (picking a keeper flips
/// the row out of `selectable`) would skip the pop and strand a pointing hand on the global stack,
/// one more per pick. Recording the push makes the pop independent of anything that changes
/// underneath.
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
            // A row in a LazyVStack is torn down by scrolling, a section folding, a filter, and its
            // own group being resolved, none of which delivers `onHover(false)`.
            .onDisappear {
                if pushedCursor { NSCursor.pop(); pushedCursor = false }
            }
    }
}

extension View {
    /// See ``PointingHandCursor``.
    func pointingHandCursor() -> some View { modifier(PointingHandCursor()) }
}

/// A context menu that is attached only when it has something in it.
///
/// `.contextMenu { }` has no "absent" form: a builder that produces nothing still leaves the
/// modifier on. So the choice is made here, once, outside the builder; see
/// ``DuplicateGroupCard/hasRowMenu(_:)`` for why an empty one isn't harmless.
struct RowMenu<Items: View>: ViewModifier {
    let isAttached: Bool
    @ViewBuilder let items: () -> Items

    func body(content: Content) -> some View {
        if isAttached {
            content.contextMenu { items() }
        } else {
            content
        }
    }
}
