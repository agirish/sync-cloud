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
    let onToggle: () -> Void
    let onApply: () -> Void
    let onReveal: () -> Void
    let onKeepSeparate: () -> Void
    let onChooseKeeper: (String) -> Void
    let onMerge: () -> Void

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
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
            .padding(.vertical, 12)
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
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(accent.opacity(0.14)))
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
                .foregroundStyle(.green)
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

    private func copyRow(_ copy: DuplicateCopy) -> some View {
        HStack(alignment: .top, spacing: 12) {
            radio(copy)
            VStack(alignment: .leading, spacing: 4) {
                breadcrumb(for: copy.path)
                Text(metaLine(copy))
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            fateChip(copy)
        }
        .padding(.vertical, 11)
    }

    /// The keeper radio. Interactive (click to keep a different copy) for identical & versions;
    /// a static indicator otherwise.
    @ViewBuilder
    private func radio(_ copy: DuplicateCopy) -> some View {
        if group.allowsKeeperChoice, !copy.isRecommendedKeeper {
            Button { onChooseKeeper(copy.id) } label: { radioIcon(copy) }
                .buttonStyle(.plain)
                .help("Keep this copy instead")
        } else {
            radioIcon(copy)
        }
    }

    private func radioIcon(_ copy: DuplicateCopy) -> some View {
        Image(systemName: copy.isRecommendedKeeper ? "largecircle.fill.circle" : "circle")
            .font(.system(size: 15))
            .foregroundStyle(copy.isRecommendedKeeper ? Color.green : Color.secondary)
            .padding(.top, 1)
    }

    private func fateChip(_ copy: DuplicateCopy) -> some View {
        Group {
            if copy.isRecommendedKeeper {
                chip("Keep", systemImage: "checkmark", color: .green)
            } else {
                switch group.matchType {
                case .identical, .versions:
                    chip("Move to Trash", systemImage: "trash", color: .red)
                case .overlapping:
                    chip("Fold in", systemImage: "arrow.triangle.merge", color: .orange)
                case .nameOnly:
                    chip("Different", systemImage: "circle.slash", color: .secondary)
                }
            }
        }
    }

    private func chip(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(color.opacity(0.14)))
        .fixedSize()
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
                    .foregroundStyle(.blue)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.04)))
            .padding(.top, 10)
        }
    }

    private var noteText: String? {
        switch group.matchType {
        case .identical:
            return "Every item in the removed \(group.isDirectory ? "copy" : "file") also exists in the copy you're keeping. Nothing is lost — removed copies go to the Trash and can be restored with Undo."
        case .versions:
            return "The newest version is kept; older versions move to the Trash and can be restored with Undo."
        case .overlapping(let f):
            let unique = group.redundantCopies.reduce(0) { $0 + $1.uniqueItemCount }
            let many = group.redundantCopies.count != 1
            return "These folders share \(Int((f * 100).rounded()))% of their contents; the other cop\(many ? "ies add" : "y adds") \(unique) unique item\(unique == 1 ? "" : "s"). Merging copies those into “\(group.keeper.name)”, then moves the folded cop\(many ? "ies" : "y") to the Trash. Nothing is lost — reversible with ⌘Z."
        case .nameOnly:
            return "Same name, different contents — likely two unrelated things. Tidy won't remove either; keep them separate, or rename one to disambiguate."
        }
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
            } else if group.matchType.kind == .overlapping {
                Button(action: onMerge) {
                    Label("Merge into keeper", systemImage: "arrow.triangle.merge")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
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
        if let root = scanRoot, path.hasPrefix(root) {
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
