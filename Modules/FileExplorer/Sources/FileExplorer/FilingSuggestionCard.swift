import SwiftUI
import Sync
import Design

/// One loose file rendered as a Filing suggestion card, matching the Filing mockup: the file, its
/// source, the suggested destination (with "new" tags on folders that would be created), the
/// reason, a confidence chip, and the file/choose/leave actions.
struct FilingSuggestionCard: View {
    let suggestion: FilingSuggestion
    /// Row measurements per the appearance density setting (H7/D4), injected by the owner
    /// (TidyView reads the @AppStorage once and passes the resolved metrics down). Comfortable
    /// is the pre-density look — its values equal the literals this card used to hard-code.
    let densityMetrics: ListDensityMetrics
    let onFileHere: (FilingDestination) -> Void
    let onChooseFolder: () -> Void
    let onReveal: () -> Void
    let onNotHere: () -> Void
    /// Quick Look the file. nil hides the Preview button.
    var onPreview: (() -> Void)? = nil
    /// Reject the current folder and get a different suggestion. nil hides the button.
    var onTryAnother: (() -> Void)? = nil
    /// True while this card's re-ask is out at the classifier. The manager ignores a re-entrant
    /// "Try another" for the same card, so without this the second click is silently inert — the
    /// button must look busy rather than look ready and do nothing.
    var isTryAnotherBusy: Bool = false
    /// Read this file with OCR — offered only for a PDF the scan read and got nothing from, i.e. a
    /// scan with no text layer. nil hides the button.
    ///
    /// **An offer, not something the scan does.** Rendering a page and running Vision over it
    /// measured 0.5–2.1 s per file; for the card in front of you that is a click, for a 500-file
    /// inbox it is ten minutes of fans spent on files you may not care about. So the suggestion on
    /// such a card was reached without the document, and this is how you say "actually read it".
    var onReadScan: (() -> Void)? = nil
    /// True while this card's OCR is running — same reason as `isTryAnotherBusy`: the manager
    /// ignores a re-entrant click, so the button must look busy rather than look ready and do
    /// nothing. The wait is seconds, which is long enough to click twice.
    var isReadScanBusy: Bool = false

    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }
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
                        .scaledFont(.system(size: 14, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle)
                    // The source and "why" lines are the secondary detail compact hides (D4); the
                    // destination row and the actions still carry what happens and where.
                    if densityMetrics.showsSecondaryDetail { sourceRow }
                    if let best {
                        if densityMetrics.showsSecondaryDetail {
                            destinationRow(best)
                        } else if let rationale = rationale(best) {
                            // Compact hides the whyRow (which carried the filing rationale for
                            // VoiceOver) — keep the "why here" reachable on the destination row.
                            // Combined first (the whyRow precedent below): the destination row is
                            // a multi-element HStack, and an `.accessibilityValue` on an uncombined
                            // container may never be voiced — VO walks the children individually.
                            destinationRow(best)
                                .accessibilityElement(children: .combine)
                                .help(rationale)
                                .accessibilityValue(rationale)
                        } else {
                            destinationRow(best)
                        }
                    }
                    // The rename, whenever one is coming. **Never hidden by density**: every other
                    // secondary line here describes the move, and this one describes a SECOND thing
                    // that happens to the file. A card that showed only "→ PG&E › 2025" while the
                    // apply also renamed the file would be under-reporting what the button does,
                    // and compact mode is exactly where that would go unnoticed.
                    if let renamed = best?.proposedName { renameRow(renamed) }
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
        .lensCard()
    }

    private var sourceRow: some View {
        let parent = ((suggestion.filePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return Text("from \(parent) · \(FileSyncManager.formatBytes(suggestion.size))")
            .scaledFont(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
    }

    private func destinationRow(_ dest: FilingDestination) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.turn.down.right")
                .scaledFont(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            breadcrumb(dest)
            if let peek = destinationPeekLabel(dest) {
                Text("· \(peek)")
                    .scaledFont(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("Files already in the destination folder")
            }
        }
        .task(id: dest.path) { await loadDestinationCount(for: dest) }
    }

    /// "also renamed 04. Apr 2025.pdf" — what the file will be called once it lands.
    ///
    /// It is on the card because the apply path is gated on it: a destination that proposes a name
    /// gets one applied, and one that does not leaves the filename alone. So this line is not a
    /// decoration but the disclosure of the second half of what "File here" does.
    private func renameRow(_ proposed: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "character.cursor.ibeam")
                .scaledFont(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("also renamed")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Text(proposed)
                .scaledFont(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .combine)
        .help("This folder names its files by a convention, so filing this one also renames it to "
              + "“\(proposed)”.")
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
    /// A nil result is deliberately NOT written back: it means either "unreadable" (the field is
    /// already nil, so writing changes nothing) or "superseded" — see ``DestinationPeek``.
    private func loadDestinationCount(for dest: FilingDestination) async {
        destinationItemCount = nil   // drop any stale count from a prior destination while reloading
        guard !dest.isNew else { return }
        guard let count = await DestinationPeek.itemCount(atPath: dest.path) else { return }
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
                Text("…").scaledFont(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
            }
            ForEach(Array(shown.enumerated()), id: \.offset) { i, comp in
                if i > 0 || truncated {
                    Text("›").scaledFont(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
                let isNew = dest.isNew && i >= newStart
                let isLeaf = i == shown.count - 1
                HStack(spacing: 3) {
                    Text(comp)
                        .scaledFont(.system(size: 12, weight: isLeaf ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(isNew ? hueAccent : (isLeaf ? Color.primary : Color.secondary))
                    if isNew {
                        // Deliberately NOT a full Pill.mini: its 10pt text and H8/V2 padding
                        // balloon an 8pt tag inline in a five-crumb breadcrumb. Only the wash
                        // opacity is unified with the shared pill recipe.
                        Text("NEW")
                            .scaledFont(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(hueAccent.opacity(PillVariant.fillOpacity)))
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

    /// The full "why here" rationale as one string: the stated reason (or the content-evidence
    /// sentence when there's no prose reason) plus the neighbor-corroboration note when the
    /// destination already holds similar files. The single source for BOTH the whyRow's VoiceOver
    /// label and the compact fallback's tooltip/`accessibilityValue`, so the two surfaces can't
    /// drift and compact keeps the "N similar files already here" detail.
    private func rationale(_ dest: FilingDestination) -> String? {
        let base: String
        if let reason = dest.reasons.first {
            base = reason
        } else if let token = dest.evidenceToken {
            base = "Matched \(token) read from the file"
        } else {
            return nil
        }
        guard let note = neighborNote(dest) else { return base }
        return "\(base) · \(note)"
    }

    // MARK: G4 — legible content evidence

    @ViewBuilder
    private func whyRow(_ dest: FilingDestination) -> some View {
        if let token = dest.evidenceToken {
            // Content-derived (F2): the deciding word was read from the file, not its name — the
            // stronger, less-obvious signal. Highlight it so it reads distinctly from a name match.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "doc.text.magnifyingglass").scaledFont(.system(size: 11)).foregroundStyle(SemanticColor.success)
                Text("Matched").scaledFont(.system(size: 12)).foregroundStyle(.secondary)
                Text(token)
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule(style: .continuous).fill(SemanticColor.success.opacity(0.14)))
                    .foregroundStyle(SemanticColor.success)
                Text(evidenceTail(dest)).scaledFont(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(rationale(dest) ?? "Matched \(token) \(evidenceTail(dest))")
        } else if let reason = dest.reasons.first {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").scaledFont(.system(size: 11)).foregroundStyle(SemanticColor.info)
                Text(reason).scaledFont(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The descriptive tail after the highlighted evidence chip, naming the neighbor corroboration
    /// ("N similar files already here") when the target already holds matching files.
    private func evidenceTail(_ dest: FilingDestination) -> String {
        guard let note = neighborNote(dest) else { return "read from the file" }
        return "read from the file · \(note)"
    }

    /// "N similar file(s) already here" when the destination already holds matching files; nil
    /// otherwise. Shared by the visible `evidenceTail` and the `rationale` string so the neighbor
    /// wording exists exactly once.
    private func neighborNote(_ dest: FilingDestination) -> String? {
        guard dest.neighborMatches > 0 else { return nil }
        return "\(dest.neighborMatches) similar file\(dest.neighborMatches == 1 ? "" : "s") already here"
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
        case .high?:   (text, color, symbol) = ("High", SemanticColor.success, "checkmark")
        case .medium?: (text, color, symbol) = ("Medium", SemanticColor.warning, "circle.dashed")
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
                    .chromeHover()
                Button(action: onChooseFolder) { Label("Choose folder…", systemImage: "folder") }
                    .controlSize(.small)
            } else {
                Button(action: onChooseFolder) { Label("Choose a folder…", systemImage: "folder") }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .chromeHover()
            }
            if best != nil, let onTryAnother {
                Button(action: onTryAnother) { Label("Try another", systemImage: "arrow.triangle.2.circlepath") }
                    .controlSize(.small)
                    .disabled(isTryAnotherBusy)
                    .help("Reject this folder and suggest a different one — remembered for next time")
            }
            if let onReadScan {
                Button(action: onReadScan) {
                    Label(isReadScanBusy ? "Reading…" : "Read scan",
                          systemImage: "text.viewfinder")
                }
                .controlSize(.small)
                .disabled(isReadScanBusy)
                .help("This PDF has no text layer, so the suggestion was made from its name alone. "
                      + "Read it with OCR and suggest again — a second or two.")
            }
            if let onPreview {
                Button(action: onPreview) { Label("Preview", systemImage: "eye") }
                    .controlSize(.small)
            }
            Button(action: onReveal) { Label("Reveal", systemImage: RevealGlyph.inFinder) }
                .controlSize(.small)
            Button(action: onNotHere) {
                Label("Not here", systemImage: "xmark")
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.hoverAffordance(.segment, tint: hueAccent)).controlSize(.small)
        }
    }
}

// MARK: - Destination peek (G6)

/// Reads the "· N items" peek for a Filing destination off the render path.
///
/// Extracted from the card so the CANCELLATION rule is testable, because that rule is the whole
/// point of this type. The card loads the peek from `.task(id: dest.path)`, which cancels the
/// in-flight read when "Try another" swaps the destination — but `Task.detached` does not inherit
/// cancellation, so a slow cloud directory listing for the OLD destination keeps running and can
/// resolve AFTER the new one. Without a cancellation check the loser of that race writes last and
/// the card shows the old folder's item count under the new folder's name — a wrong fact about a
/// destination the user is deciding on.
enum DestinationPeek {
    /// The number of visible (non-dot) entries in `path`, or nil when there is nothing to publish:
    /// the folder was unreadable, or this task was superseded while the listing ran. Both mean the
    /// caller must NOT write — in the superseded case another read already owns the field, and
    /// stamping it (even with nil) would blank a count that is correct for what's on screen.
    static func itemCount(atPath path: String) async -> Int? {
        let count = await Task.detached(priority: .utility) { () -> Int? in
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
            return entries.filter { !$0.hasPrefix(".") }.count
        }.value
        // Checked AFTER the await, not before: the read is only stale once it has finished late.
        // (Same shape as FileTreeView's download-watch poll, which re-checks `Task.isCancelled`
        // after each detached lstat before touching its badge state.)
        guard !Task.isCancelled else { return nil }
        return count
    }
}
