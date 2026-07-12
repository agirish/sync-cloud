import SwiftUI
import Sync
import Design

/// One loose file rendered as a Filing suggestion card, matching the Filing mockup: the file, its
/// source, the suggested destination (with "new" tags on folders that would be created), the
/// reason, a confidence chip, and the file/choose/leave actions.
struct FilingSuggestionCard: View {
    let suggestion: FilingSuggestion
    let onFileHere: (FilingDestination) -> Void
    let onChooseFolder: () -> Void
    let onReveal: () -> Void
    let onNotHere: () -> Void
    /// Quick Look the file. nil hides the Preview button.
    var onPreview: (() -> Void)? = nil

    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }

    private var best: FilingDestination? { suggestion.best }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: FileIconCache.icon(name: suggestion.fileName, isDirectory: false))
                    .resizable().frame(width: 26, height: 26)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(suggestion.fileName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    sourceRow
                    if let best { destinationRow(best) }
                    if best?.remembered == true { rememberedBadge }
                    else if best?.fromAI == true { aiBadge }
                    if let reason = best?.reasons.first { whyRow(reason) }
                }
                Spacer(minLength: 8)
                confidenceChip
            }
            .padding(.horizontal, 14).padding(.top, 12)
            actions
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 12)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var sourceRow: some View {
        let parent = ((suggestion.filePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return Text("from \(parent) · \(FileSyncManager.formatBytes(suggestion.size))")
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundStyle(.tertiary)
    }

    private func destinationRow(_ dest: FilingDestination) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            breadcrumb(dest)
        }
    }

    private func breadcrumb(_ dest: FilingDestination) -> some View {
        let comps = dest.path.split(separator: "/").map(String.init)
        let shown = Array(comps.suffix(5))
        let truncated = comps.count > shown.count
        let newStart = max(0, shown.count - dest.newSegments.count)
        return HStack(spacing: 4) {
            if truncated {
                Text("…").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, comp in
                if i > 0 || truncated {
                    Text("›").font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
                let isNew = dest.isNew && i >= newStart
                let isLeaf = i == shown.count - 1
                HStack(spacing: 3) {
                    Text(comp)
                        .font(.system(size: 12, weight: isLeaf ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(isNew ? hueAccent : (isLeaf ? Color.primary : Color.secondary))
                    if isNew {
                        Text("NEW")
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(hueAccent.opacity(0.16)))
                            .foregroundStyle(hueAccent)
                    }
                }
            }
        }
    }

    private var rememberedBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "memories").font(.system(size: 9, weight: .semibold))
            Text("Remembered").font(.system(size: 9.5, weight: .bold))
        }
        .foregroundStyle(hueAccent)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(hueAccent.opacity(0.14)))
    }

    private var aiBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold))
            Text("AI suggestion").font(.system(size: 9.5, weight: .bold))
        }
        .foregroundStyle(hueAccent)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(hueAccent.opacity(0.14)))
    }

    private func whyRow(_ reason: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.blue)
            Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var confidenceChip: some View {
        let (text, color, symbol): (String, Color, String)
        switch best?.confidence {
        case .high?:   (text, color, symbol) = ("High", .green, "checkmark")
        case .medium?: (text, color, symbol) = ("Medium", .orange, "circle.dashed")
        default:       (text, color, symbol) = ("Pick a home", .secondary, "questionmark")
        }
        return HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
            Text(text).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9).padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(color.opacity(0.14)))
        .fixedSize()
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 9) {
            if let best, suggestion.hasConfidentHome {
                Button { onFileHere(best) } label: { Label("File here", systemImage: "arrow.right.circle") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                Button(action: onChooseFolder) { Label("Choose folder…", systemImage: "folder") }
                    .controlSize(.small)
            } else {
                Button(action: onChooseFolder) { Label("Choose a folder…", systemImage: "folder") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
            }
            if let onPreview {
                Button(action: onPreview) { Label("Preview", systemImage: "eye") }
                    .controlSize(.small)
            }
            Button(action: onReveal) { Label("Reveal", systemImage: RevealGlyph.inFinder) }
                .controlSize(.small)
            Button(action: onNotHere) { Label("Not here", systemImage: "xmark") }
                .buttonStyle(.borderless).controlSize(.small)
        }
    }
}
