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
    /// Reject the current folder and get a different suggestion. nil hides the button.
    var onTryAnother: (() -> Void)? = nil

    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }
    /// Row measurements per the appearance density setting (H7/D4); comfortable is the pre-density
    /// look — its values equal the literals this card used to hard-code.
    private var densityMetrics: ListDensityMetrics {
        (ListDensity(rawValue: listDensityRaw) ?? .comfortable).metrics
    }
    /// File-icon side: the pre-density 26pt in comfortable, a tighter 20pt in compact.
    private var iconSize: CGFloat { densityMetrics.showsSecondaryDetail ? 26 : 20 }

    /// Count of the destination folder's existing entries (G6 "peek"), loaded off the render path.
    /// nil until counted / when the destination doesn't exist yet.
    @State private var destinationItemCount: Int? = nil

    private var best: FilingDestination? { suggestion.best }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: FileIconCache.icon(name: suggestion.fileName, isDirectory: false))
                    .resizable().frame(width: iconSize, height: iconSize)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(suggestion.fileName)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    // The source and "why" lines are the secondary detail compact hides (D4); the
                    // destination row and the actions still carry what happens and where.
                    if densityMetrics.showsSecondaryDetail { sourceRow }
                    if let best { destinationRow(best) }
                    if best?.remembered == true { rememberedBadge }
                    else if best?.fromAI == true { aiBadge }
                    if densityMetrics.showsSecondaryDetail, let best { whyRow(best) }
                }
                Spacer(minLength: 8)
                confidenceCluster
            }
            .padding(.horizontal, 14).padding(.top, densityMetrics.cardHeaderVerticalPadding)
            actions
                .padding(.horizontal, 14)
                .padding(.top, densityMetrics.cardHeaderVerticalPadding)
                .padding(.bottom, densityMetrics.cardHeaderVerticalPadding)
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
            if let peek = destinationPeekLabel(dest) {
                Text("· \(peek)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("Files already in the destination folder")
            }
        }
        .task(id: dest.path) { await loadDestinationCount(for: dest) }
    }

    // MARK: G6 — destination "peek" (existing contents)

    /// A short "· N items" / "· empty" label for the destination's current contents. nil while the
    /// count is loading, or when the folder doesn't exist yet (a proposed NEW folder has no peek —
    /// the NEW badges already say it'll be created).
    private func destinationPeekLabel(_ dest: FilingDestination) -> String? {
        guard !dest.isNew, let count = destinationItemCount else { return nil }
        return count == 0 ? "empty" : "\(count) item\(count == 1 ? "" : "s")"
    }

    /// Counts the destination folder's visible entries off the render path (small folders, cheap).
    private func loadDestinationCount(for dest: FilingDestination) async {
        destinationItemCount = nil   // drop any stale count from a prior destination while reloading
        guard !dest.isNew else { return }
        let path = dest.path
        let count = await Task.detached(priority: .utility) { () -> Int? in
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
            return entries.filter { !$0.hasPrefix(".") }.count
        }.value
        destinationItemCount = count
    }

    // MARK: G10 — home-relative breadcrumb

    private func breadcrumb(_ dest: FilingDestination) -> some View {
        let comps = breadcrumbComponents(dest)
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

    /// The breadcrumb's path components with the dead `/Users/<you>` head dropped. Provider-relative
    /// (e.g. "iCloud › Documents › …") when the suggestion knows its provider root; otherwise
    /// tilde-abbreviated ("~ › Documents › …"), reusing the app's standard home-abbreviation.
    private func breadcrumbComponents(_ dest: FilingDestination) -> [String] {
        if let root = suggestion.providerRoot, isPath(dest.path, under: root) {
            let rel = String(dest.path.dropFirst(root.count)).split(separator: "/").map(String.init)
            return [providerLabel(for: root)] + rel
        }
        return (dest.path as NSString).abbreviatingWithTildeInPath.split(separator: "/").map(String.init)
    }

    /// Whether `path` is the provider root itself or lives inside it (boundary-safe on "/").
    private func isPath(_ path: String, under root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// A friendly label for a provider root path — "iCloud" / "Dropbox" / "Google Drive" for the
    /// known cloud roots, else the root folder's own name.
    private func providerLabel(for root: String) -> String {
        let lower = root.lowercased()
        if lower.contains("com~apple~clouddocs") || lower.contains("mobile documents") { return "iCloud" }
        if let r = root.range(of: "/CloudStorage/") {
            let vendor = root[r.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            return prettifyVendor(vendor)
        }
        let last = (root as NSString).lastPathComponent
        return last.isEmpty ? "Cloud" : last
    }

    /// Turns a CloudStorage vendor folder ("GoogleDrive-me@x.com", "OneDrive-Personal") into a
    /// readable provider name.
    private func prettifyVendor(_ v: String) -> String {
        let base = v.split(separator: "-").first.map(String.init) ?? v
        switch base.lowercased() {
        case "googledrive": return "Google Drive"
        case "onedrive":    return "OneDrive"
        case "dropbox":     return "Dropbox"
        case "box":         return "Box"
        default:            return base
        }
    }

    private var rememberedBadge: some View {
        Pill(.mini, tint: hueAccent, systemImage: "memories", text: "Remembered")
    }

    private var aiBadge: some View {
        Pill(.mini, tint: hueAccent, systemImage: "sparkles", text: "AI suggestion")
    }

    // MARK: G4 — legible content evidence

    @ViewBuilder
    private func whyRow(_ dest: FilingDestination) -> some View {
        if let token = dest.evidenceToken {
            // Content-derived (F2): the deciding word was read from the file, not its name — the
            // stronger, less-obvious signal. Highlight it so it reads distinctly from a name match.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "doc.text.magnifyingglass").font(.system(size: 11)).foregroundStyle(.green)
                Text("Matched").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(token)
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule(style: .continuous).fill(Color.green.opacity(0.18)))
                    .foregroundStyle(Color.green)
                Text(evidenceTail(dest)).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(dest.reasons.first ?? "Matched \(token) read from the file")
        } else if let reason = dest.reasons.first {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 11)).foregroundStyle(.blue)
                Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The descriptive tail after the highlighted evidence chip, naming the neighbor corroboration
    /// ("N similar files already here") when the target already holds matching files.
    private func evidenceTail(_ dest: FilingDestination) -> String {
        guard dest.neighborMatches > 0 else { return "read from the file" }
        return "read from the file · \(dest.neighborMatches) similar file\(dest.neighborMatches == 1 ? "" : "s") already here"
    }

    /// The tier this card's confidence falls into — the single key shared by the chip and the meter
    /// so they can never disagree.
    private var confidenceTier: FilingConfidenceTier { FilingConfidenceTier.of(best?.confidence) }

    /// The confidence word (chip) paired with the 3-bar meter (G5), so confidence reads as a
    /// quantity, not just a color-word. The meter sits left of the chip, both tinted the same.
    private var confidenceCluster: some View {
        HStack(spacing: 6) {
            ConfidenceMeter(tier: confidenceTier)
            confidenceChip
        }
    }

    private var confidenceChip: some View {
        let (text, color, symbol): (String, Color, String)
        switch best?.confidence {
        case .high?:   (text, color, symbol) = ("High", .green, "checkmark")
        case .medium?: (text, color, symbol) = ("Medium", .orange, "circle.dashed")
        default:       (text, color, symbol) = ("Pick a home", .secondary, "questionmark")
        }
        return Pill(.mini, tint: color, systemImage: symbol, text: text)
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
            if best != nil, let onTryAnother {
                Button(action: onTryAnother) { Label("Try another", systemImage: "arrow.triangle.2.circlepath") }
                    .controlSize(.small)
                    .help("Reject this folder and suggest a different one — remembered for next time")
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
