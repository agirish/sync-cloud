import SwiftUI
import Sync
import Design

/// One duplicate group rendered as an expandable card, matching the Tidy mockup: a type badge,
/// the common name, a reclaim figure, and — when expanded — each copy with its location, the
/// recommended keeper, and the resolve actions.
struct TidyGroupCard: View {
    let group: DuplicateGroup
    let isExpanded: Bool
    let providerName: String?
    let scanRoot: String?
    /// Row measurements per the appearance density setting (H7), injected by the owner (TidyView
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

    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue

    private var accent: Color { TidyMatchStyle.color(group.matchType) }
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }

    var body: some View {
        VStack(spacing: 0) {
            header
            if isExpanded {
                Divider().overlay(Color.primary.opacity(0.06))
                body(for: group)
            }
        }
        .lensCard()
    }

    // MARK: Header

    private var header: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                typeBadge
                fileIcon
                Text(group.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                reclaimText
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, densityMetrics.cardHeaderVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var typeBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: TidyMatchStyle.symbol(group.matchType))
                .font(.system(size: 11, weight: .bold))
                .symbolRenderingMode(.hierarchical)
            Text(TidyMatchStyle.label(group.matchType))
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(accent)
        .pillSurface(.mini, tint: accent)
        .fixedSize()
    }

    private var fileIcon: some View {
        Image(nsImage: FileIconCache.icon(name: group.name, isDirectory: group.isDirectory))
            .resizable().frame(width: 17, height: 17)
    }

    private var subtitle: String {
        let n = group.copies.count
        switch group.matchType {
        case .identical:
            return group.isDirectory ? "\(n) copies · identical trees" : "\(n) copies · byte-for-byte"
        case .overlapping(let f):
            return "\(n) copies · \(Int((f * 100).rounded()))% shared"
        case .nameOnly:
            return "\(n) folders · different contents"
        case .versions:
            return "\(n) versions"
        }
    }

    @ViewBuilder
    private var reclaimText: some View {
        if case .overlapping = group.matchType, group.reclaimableBytes > 0 {
            // Overlap can't be one-click reclaimed yet (merge deferred) — report it as shared, not
            // as an actionable "reclaim", so the figure doesn't promise a button that isn't there.
            Text("~\(FileSyncManager.formatBytes(group.reclaimableBytes)) shared")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        } else if group.reclaimableBytes > 0 {
            Text("reclaim \(FileSyncManager.formatBytes(group.reclaimableBytes))")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(SemanticColor.success)
                .fixedSize()
        } else {
            Text("nothing to reclaim")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize()
        }
    }

    // MARK: Body

    private func body(for group: DuplicateGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnailStrip
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

    // MARK: Thumbnail strip

    /// Keeper-first, capped so a pathological group can't run the row off the card.
    private var thumbnailCopies: [DuplicateCopy] {
        let keeper = group.copies.filter { $0.isRecommendedKeeper }
        let rest = group.copies.filter { !$0.isRecommendedKeeper }
        return Array((keeper + rest).prefix(Self.maxThumbnails))
    }
    private static let maxThumbnails = 6

    /// A row of content previews, one per copy — shown only for file groups, where a QuickLook
    /// thumbnail confirms the copies really match before trashing. Directory groups (identical
    /// trees, name-only folders, overlapping folders) skip it: a folder icon adds no confidence,
    /// and the breadcrumbs + note already carry what they need.
    @ViewBuilder
    private var thumbnailStrip: some View {
        if !group.isDirectory {
            // Horizontal scroll so a many-copy group (or a narrow Tidy pane) never runs the tiles
            // off the card — the cap bounds how many render, this bounds how wide they reach.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(thumbnailCopies) { copy in
                        DuplicateThumbnailView(path: copy.path, name: group.name,
                                               isKeeper: copy.isRecommendedKeeper, modified: copy.modificationDate)
                    }
                    if group.copies.count > Self.maxThumbnails {
                        overflowTile(group.copies.count - Self.maxThumbnails)
                    }
                }
                // Vertical room so the hover lift isn't clipped by the scroll view; a little
                // horizontal inset so the first/last tiles aren't flush to the card edge.
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
            .padding(.top, 4)
            Divider().overlay(Color.primary.opacity(0.05))
        }
    }

    private func overflowTile(_ count: Int) -> some View {
        VStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 54, height: 54 * 1.2)
                .overlay(
                    Text("+\(count)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
            Text("more")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func copyRow(_ copy: DuplicateCopy) -> some View {
        HStack(alignment: .top, spacing: 12) {
            radio(copy)
            VStack(alignment: .leading, spacing: 4) {
                breadcrumb(for: copy.path)
                // The size/date detail line is the secondary text compact hides (H7); the
                // fate chip and breadcrumb still carry what happens to the copy and where it is.
                if densityMetrics.showsSecondaryDetail {
                    Text(metaLine(copy))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            fateChip(copy)
        }
        .padding(.vertical, densityMetrics.cardRowVerticalPadding)
    }

    /// The keeper marker. The keeper's green filled radio everywhere (it reads "this one is
    /// kept"); a clickable hollow radio with a hover glow where the user may pick a different
    /// keeper (identical & versions); a plain dot where no choice exists, so the row never
    /// advertises a pick that isn't there.
    @ViewBuilder
    private func radio(_ copy: DuplicateCopy) -> some View {
        switch TidyKeeperMarker.style(allowsKeeperChoice: group.allowsKeeperChoice,
                                      isKeeper: copy.isRecommendedKeeper) {
        case .keeper:
            Image(systemName: "largecircle.fill.circle")
                .font(.system(size: 15))
                .foregroundStyle(SemanticColor.success)
                .padding(.top, 1)
                .accessibilityLabel(TidyKeeperMarker.keeper.accessibilityLabel ?? "")
        case .selectable:
            SelectableKeeperRadio(accent: hueAccent) { onChooseKeeper(copy.id) }
        case .inert:
            Circle()
                .fill(.tertiary)
                .frame(width: 5, height: 5)
                .frame(width: 15)   // keep the text column aligned with the radio rows
                // 7 centers the dot on the radios: the 15pt-font symbols render 18pt tall with
                // ink spanning 2–17pt (center 9.5 after their 1pt top pad); 6 + 2.5 sat 1pt high.
                .padding(.top, 7)
                .accessibilityHidden(true)
        }
    }

    private func fateChip(_ copy: DuplicateCopy) -> some View {
        Group {
            if copy.isRecommendedKeeper {
                chip("Keep", systemImage: "checkmark", color: SemanticColor.success)
            } else {
                switch group.matchType {
                case .identical, .versions:
                    chip("Move to Trash", systemImage: "trash", color: SemanticColor.error)
                case .overlapping:
                    chip("Fold in", systemImage: "arrow.triangle.merge", color: SemanticColor.warning)
                case .nameOnly:
                    chip("Different", systemImage: "circle.slash", color: .secondary)
                }
            }
        }
    }

    private func chip(_ text: String, systemImage: String, color: Color) -> some View {
        Pill(.mini, tint: color, systemImage: systemImage, text: text)
    }

    private func metaLine(_ copy: DuplicateCopy) -> String {
        var parts: [String] = []
        if copy.isDirectory { parts.append("\(copy.itemCount) items") }
        parts.append(FileSyncManager.formatBytes(copy.size))
        if let d = copy.modificationDate {
            parts.append("modified \(Self.dateFormatter.string(from: d))")
        }
        if !copy.isRecommendedKeeper {
            switch group.matchType {
            case .overlapping where copy.uniqueItemCount > 0:
                parts.append("\(copy.uniqueItemCount) unique here")
            case .identical, .versions:
                parts.append(copy.isFullyRedundant ? "fully redundant" : "\(copy.uniqueItemCount) unique here")
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
                    .font(.system(size: 12))
                    .foregroundStyle(SemanticColor.info)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.04)))
            .padding(.top, 10)
        }
    }

    private var noteText: String? {
        let base: String
        switch group.matchType {
        case .identical:
            base = "Every item in the removed \(group.isDirectory ? "copy" : "file") also exists in the copy you're keeping. Nothing is lost — removed copies go to the Trash and can be restored with Undo."
        case .versions:
            base = "The newest version is kept; older versions move to the Trash and can be restored with Undo."
        case .overlapping(let f):
            let unique = group.redundantCopies.reduce(0) { $0 + $1.uniqueItemCount }
            let many = group.redundantCopies.count != 1
            base = "These folders share \(Int((f * 100).rounded()))% of their contents; the other cop\(many ? "ies add" : "y adds") \(unique) unique item\(unique == 1 ? "" : "s"). Merging copies those into “\(group.keeper.name)”, then moves the folded cop\(many ? "ies" : "y") to the Trash. Nothing is lost — reversible with ⌘Z."
        case .nameOnly:
            base = "Same name, different contents — likely two unrelated things. Tidy won't remove either; keep them separate, or rename one to disambiguate."
        }
        if let caveat = TidyUnverifiedNote.text(
            unverifiedCount: group.copies.filter { $0.contentUnverified }.count) {
            return base + " " + caveat
        }
        return base
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 9) {
            if group.isFullyResolvableByRemoval {
                Button(action: onApply) {
                    Label(applyTitle, systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isMerging)
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
                        Label("Merge into keeper", systemImage: "arrow.triangle.merge")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isMerging)
            }
            // Folder groups can be inspected side by side before deciding — identical/overlapping/
            // name-only are all directories. File "Versions" groups have the thumbnail strip instead.
            if group.isDirectory {
                compareControl
            }
            Button(action: onReveal) {
                Label("Reveal", systemImage: RevealGlyph.inFinder)
            }
            .controlSize(.small)
            Button(action: onKeepSeparate) {
                Label("Keep separate", systemImage: "lock")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(isMerging)   // would drop the group from the list mid-merge
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var applyTitle: String {
        switch group.matchType {
        case .versions: return "Keep newest, Trash older"
        default: return group.copies.count > 2 ? "Keep one, Trash the rest" : "Trash redundant copy"
        }
    }

    /// "Compare copies": a direct button when there's a single redundant copy (a 2-copy group), or a
    /// menu to pick which redundant copy to compare against the keeper when there are more than two —
    /// Compare has exactly two panes, so bigger groups are reviewed two at a time (keeper vs each).
    @ViewBuilder
    private var compareControl: some View {
        if group.redundantCopies.count <= 1 {
            Button {
                if let other = group.redundantCopies.first { onCompareCopies(group.keeper, other) }
            } label: {
                Label("Compare copies", systemImage: "rectangle.split.2x1")
            }
            .controlSize(.small)
        } else {
            Menu {
                ForEach(group.redundantCopies) { copy in
                    Button(location(for: copy.path)) { onCompareCopies(group.keeper, copy) }
                }
            } label: {
                Label("Compare with…", systemImage: "rectangle.split.2x1")
            }
            .menuStyle(.borderlessButton)
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

    private func breadcrumb(for path: String) -> some View {
        let comps = crumbs(path)
        return HStack(spacing: 5) {
            ForEach(Array(comps.enumerated()), id: \.offset) { idx, comp in
                if idx > 0 {
                    Text("›").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
                if idx == comps.count - 1 {
                    Text(comp)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 5).fill(hueAccent.opacity(0.14)))
                } else {
                    Text(comp)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(idx == 0 && providerName != nil ? hueAccent : .secondary)
                }
            }
        }
    }

    private func crumbs(_ path: String) -> [String] {
        // Boundary-safe on "/" (same rule as FilingSuggestionCard.isPath): a scan root of
        // "/data/Docs" must not claim "/data/DocsBackup/…" and strip it to "Backup/…".
        if let root = scanRoot, path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") {
            let rel = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var comps = rel.isEmpty ? [] : rel.components(separatedBy: "/")
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

// MARK: - Unverified-content note

/// Pure wording for the card's caveat when some copies in a group could not be content-verified
/// (hash skipped: too large, cloud-only, unreadable) — the group's content claim rests on less
/// than full verification, and the note must say so before the user trusts a one-click resolve.
enum TidyUnverifiedNote {
    static func text(unverifiedCount count: Int) -> String? {
        guard count > 0 else { return nil }
        let plural = count != 1
        return "\(count) cop\(plural ? "ies" : "y") couldn't be content-verified (too large to hash, or not downloaded from the cloud) — review before removing anything."
    }
}

/// The scan-level counterpart to ``TidyUnverifiedNote``: wording for the summary row's "skipped"
/// pill tooltip when the duplicate scan skipped candidate files during hashing entirely, spelling
/// out the per-reason split. Only reasons that actually occurred are listed, so the tooltip never
/// mentions an empty category.
enum TidyScanSkipNote {
    static func text(_ skips: FileSyncManager.DuplicateScanSkips) -> String? {
        guard skips.total > 0 else { return nil }
        var reasons: [String] = []
        if skips.tooLarge > 0 { reasons.append("\(skips.tooLarge) too large to hash") }
        if skips.cloudOnly > 0 { reasons.append("\(skips.cloudOnly) cloud-only (not downloaded)") }
        let plural = skips.total != 1
        return "\(skips.total) file\(plural ? "s" : "") couldn't be content-checked: \(reasons.joined(separator: ", ")). Identical copies among them are not detected."
    }
}

// MARK: - Keeper marker

/// Pure mapping from (does this group allow picking a keeper?, is this copy the keeper?) to the
/// marker its row shows, so inert rows never draw a radio that looks pickable.
enum TidyKeeperMarker: Equatable {
    /// Green filled radio — this copy is kept.
    case keeper
    /// Hollow radio, clickable — the user may keep this copy instead.
    case selectable
    /// Small tertiary dot — no keeper choice exists in this group.
    case inert

    static func style(allowsKeeperChoice: Bool, isKeeper: Bool) -> TidyKeeperMarker {
        if isKeeper { return .keeper }
        return allowsKeeperChoice ? .selectable : .inert
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

/// The clickable "keep this copy instead" radio: hollow circle that gains an accent tint, a soft
/// glow ring, and a pointing-hand cursor on hover, so pickable radios read differently from the
/// static keeper indicator.
private struct SelectableKeeperRadio: View {
    let accent: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "circle")
                .font(.system(size: 15))
                .foregroundStyle(isHovering ? accent : Color.secondary)
                .background(
                    Circle()
                        .fill(accent.opacity(isHovering ? 0.18 : 0))
                        .frame(width: 26, height: 26)
                )
                .padding(.top, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Keep this copy instead")
        .accessibilityLabel(TidyKeeperMarker.selectable.accessibilityLabel ?? "")
        .onHover { inside in
            // NSCursor's stack is global and SwiftUI may repeat onHover(true) without an
            // intervening false (layout thrash), so push/pop only on real transitions:
            // exactly one push per hovered state, and pop only what we pushed.
            switch HoverCursorTransition.decide(wasHovering: isHovering, isNowInside: inside) {
            case .push: NSCursor.pointingHand.push()
            case .pop: NSCursor.pop()
            case .none: break
            }
            isHovering = inside
        }
        .onDisappear {
            // Choosing a keeper reorders the rows out from under the cursor; don't leave the
            // pushed pointing hand stranded on the cursor stack.
            if isHovering {
                NSCursor.pop()
                isHovering = false
            }
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
