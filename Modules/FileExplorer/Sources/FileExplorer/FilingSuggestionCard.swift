import SwiftUI
import Sync
import Design

/// One loose file as a Filing suggestion card: the file, its source, the suggested destination
/// ("new" tags on folders that would be created), the reason, a confidence chip, and the actions.
struct FilingSuggestionCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let suggestion: FilingSuggestion
    /// Row measurements for the density setting, passed down by `LensWorkspaceView`, which reads
    /// the @AppStorage once.
    let densityMetrics: ListDensityMetrics
    let onFileHere: (FilingDestination) -> Void
    let onChooseFolder: () -> Void
    let onReveal: () -> Void
    let onNotHere: () -> Void
    /// Quick Look the file. nil hides the Preview button.
    var onPreview: (() -> Void)? = nil
    /// Reject the current folder and get a different suggestion. nil hides the button.
    var onTryAnother: (() -> Void)? = nil
    /// True while this card's re-ask is out at the classifier. The manager ignores a second "Try
    /// another" meanwhile, so the button must look busy rather than ready.
    var isTryAnotherBusy: Bool = false
    /// Read this file with OCR, offered only for a PDF with no text layer. nil hides the button.
    /// An offer, not part of the scan: OCR takes 0.5–2 s a file, fine for one card but minutes for a
    /// large inbox, so such a card's suggestion was made without the document's text.
    var onReadScan: (() -> Void)? = nil
    /// True while this card's OCR runs, for `isTryAnotherBusy`'s reason: the wait is seconds, long
    /// enough to click twice.
    var isReadScanBusy: Bool = false
    /// The file is only in the cloud, so its home was chosen from its name alone. The card says so,
    /// since that is why such a suggestion can be weak; Download and Read, above the list, fixes it.
    var isNotDownloaded: Bool = false

    /// The name typed into "Create as" over a proposed new folder, empty while untouched: the
    /// proposed name is the model's, not the user's, so they can change it before filing.
    ///
    /// Cleared whenever the destination changes. The card's identity is the suggestion, and "Try
    /// another" swaps the destination under it, so a stale name would be applied to the next one.
    @State private var editedFolderName: String = ""

    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }
    /// File-icon side: 26pt in comfortable, 20pt in compact.
    private var iconSize: CGFloat { densityMetrics.showsSecondaryDetail ? 26 : 20 }

    /// Count of the destination folder's entries (the "peek"), loaded off the render path. nil until
    /// counted, or when the destination doesn't exist yet.
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
                    // Compact hides the source and "why" lines; the destination row and actions
                    // still say what happens and where.
                    if densityMetrics.showsSecondaryDetail { sourceRow }
                    if let best {
                        if densityMetrics.showsSecondaryDetail {
                            destinationRow(best)
                        } else if let rationale = rationale(best) {
                            // Compact hides the whyRow, so the rationale moves to the destination
                            // row. Combined first: VoiceOver walks an uncombined HStack's children
                            // and may never voice an `.accessibilityValue` on the container.
                            destinationRow(best)
                                .accessibilityElement(children: .combine)
                                .help(rationale)
                                .accessibilityValue(rationale)
                        } else {
                            destinationRow(best)
                        }
                    }
                    // The rename, whenever one is coming. Never hidden by density: it is a second
                    // thing "File here" does to the file, and hiding it under-reports the button.
                    if let renamed = best?.proposedName { renameRow(renamed) }
                    // Never hidden by density, like the rename line: it says the tree already has
                    // this document, so "File here" would make a second copy.
                    if suggestion.isAlreadyFiled { alreadyFiledRow }
                    if isNotDownloaded { notDownloadedRow }
                    if best?.remembered == true { rememberedBadge }
                    else if best?.fromAI == true { aiBadge }
                    if densityMetrics.showsSecondaryDetail, let best { whyRow(best) }
                    if let best, best.isNew { newFolderNameField(best) }
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
        // The typed name belongs to the destination it was typed for: "Try another" swaps `best`
        // under this card and `@State` survives. Keyed on the proposed leaf, the string the field
        // edits, so the same name under a different parent keeps what the user typed.
        .onChange(of: best?.newSegments.last) { _, _ in editedFolderName = "" }
    }

    private var sourceRow: some View {
        let parent = ((suggestion.filePath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return Text("from \(parent) · \(FileSyncManager.formatBytes(suggestion.size))")
            .scaledFont(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
    }

    private var notDownloadedRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "icloud")
                .scaledFont(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text("Not downloaded · placed by name")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .lineLimit(1)
        .help("This file is only in the cloud, so To File couldn’t read it. Download and Read fetches it and reads page 1.")
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

    /// "also renamed 04. Apr 2025.pdf": what the file will be called once it lands. A destination
    /// that proposes a name gets it applied, so this discloses the second half of "File here".
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

    /// A short "· N items" or "· empty" label for the destination's contents. nil while loading, or
    /// for a proposed new folder, whose NEW badges already say it'll be created.
    private func destinationPeekLabel(_ dest: FilingDestination) -> String? {
        guard !dest.isNew, let count = destinationItemCount else { return nil }
        return count == 0 ? "empty" : "\(count) item\(count == 1 ? "" : "s")"
    }

    /// Counts the destination folder's visible entries off the render path. A nil result is not
    /// written back: it means unreadable (already nil) or superseded; see ``DestinationPeek``.
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
                        // Not a full Pill.mini: its 10pt text and padding balloon an 8pt tag in a
                        // five-crumb breadcrumb. Only the wash opacity is shared with the pill.
                        Text("NEW")
                            .scaledFont(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(hueAccent.opacity(PillVariant.fillOpacity)))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    /// The breadcrumb's path components without the `/Users/<you>` head: provider-relative
    /// ("iCloud › Documents › …") when the provider root is known, else tilde-abbreviated.
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

    /// A friendly label for a provider root: "iCloud", "Dropbox", "Google Drive" and so on for known
    /// cloud roots, else the root folder's own name.
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

    /// An editable name for the folder that would be created. Only for a new destination: renaming an
    /// existing one would propose a different folder (``FilingDestination/renamingNewFolder(to:)``
    /// refuses that).
    @ViewBuilder
    private func newFolderNameField(_ dest: FilingDestination) -> some View {
        if let leaf = dest.newSegments.last {
            HStack(spacing: 6) {
                Image(systemName: "folder.badge.plus")
                    .scaledFont(.system(size: 11)).foregroundStyle(hueAccent)
                Text("Create as").scaledFont(.system(size: 12)).foregroundStyle(.secondary)
                TextField(leaf, text: $editedFolderName)
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(.system(size: 12))
                    .frame(maxWidth: 220)
                    .help("The name of the folder that will be created. Leave it to accept “\(leaf)”.")
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Create as \(editedFolderName.isEmpty ? leaf : editedFolderName)")
        }
    }

    /// "already filed in Work › EMP › … › 2026": the tree already holds this document. Matched by
    /// content (the PDF text fingerprint), not name or bytes, so two downloads of one statement
    /// pair up; hence "this document", since the copy likely differs in name and size.
    private var alreadyFiledRow: some View {
        let folders = suggestion.alreadyFiledAt
        let shown = folders[0].split(separator: "/").joined(separator: " › ")
        let more = folders.count - 1
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Readable ink for glyph and words alike rather than raw orange, as Settings' person row
            // does for its caveat.
            Image(systemName: "doc.on.doc")
                .scaledFont(.system(size: 10, weight: .semibold))
                .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.warning))
            Text("already filed in")
                .scaledFont(.system(size: 11))
                .foregroundStyle(ChromeInk.bodyText(colorScheme, SemanticColor.warning))
                .fixedSize()
            Text(shown)
                .scaledFont(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            if more > 0 {
                Text("+\(more)")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibleAlreadyFiled))
        .help(accessibleAlreadyFiled)
    }

    /// The full sentence, naming every folder: the row truncates to "+2", but a tooltip and
    /// VoiceOver have room to say which two.
    private var accessibleAlreadyFiled: String {
        let names = suggestion.alreadyFiledAt.map { $0.split(separator: "/").joined(separator: " › ") }
        return "This document is already filed in \(names.joined(separator: ", ")). "
            + "Filing it here would make a second copy."
    }

    private var rememberedBadge: some View {
        Pill(.mini, tint: hueAccent, systemImage: "memories", text: "Remembered")
    }

    private var aiBadge: some View {
        Pill(.mini, tint: hueAccent, systemImage: "sparkles", text: "AI suggestion")
    }

    /// The full "why here" as one string: the stated reason (or the content-evidence sentence) plus
    /// the similar-files note. One source for the whyRow's VoiceOver label and compact's
    /// tooltip and `accessibilityValue`, so the two can't drift.
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
            // The deciding word was read from the file, not its name: the stronger signal, so it is
            // highlighted to read apart from a name match.
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: "doc.text.magnifyingglass").scaledFont(.system(size: 11)).foregroundStyle(SemanticColor.success)
                Text("Matched").scaledFont(.system(size: 12)).foregroundStyle(.secondary)
                Text(token)
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule(style: .continuous).fill(SemanticColor.success.opacity(0.14)))
                    .foregroundStyle(.primary)
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

    /// The text after the evidence chip, with the similar-files note when there is one.
    private func evidenceTail(_ dest: FilingDestination) -> String {
        guard let note = neighborNote(dest) else { return "read from the file" }
        return "read from the file · \(note)"
    }

    /// "N similar file(s) already here", or nil. Shared by `evidenceTail` and `rationale` so the
    /// wording exists once.
    private func neighborNote(_ dest: FilingDestination) -> String? {
        guard dest.neighborMatches > 0 else { return nil }
        return "\(dest.neighborMatches) similar file\(dest.neighborMatches == 1 ? "" : "s") already here"
    }

    /// The tier this card's confidence falls into, shared by the chip and meter so they agree.
    private var confidenceTier: FilingConfidenceTier { FilingConfidenceTier.of(best?.confidence) }

    /// The confidence chip with the 3-bar meter to its left, both tinted alike, so confidence reads
    /// as a quantity, not just a word.
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
                // The typed name, when the user typed one — see `newFolderNameField`.
                Button { onFileHere(best.renamingNewFolder(to: editedFolderName)) } label: {
                    Label("File Here", systemImage: "arrow.right.circle")
                }
                    .buttonStyle(.borderedProminent).accentedProminent().controlSize(.small)
                    .chromeHover()
                    .lockedDuringRun()
                Button(action: onChooseFolder) { Label("Choose a Folder…", systemImage: "folder") }
                    .controlSize(.small)
                    .lockedDuringRun()
            } else {
                Button(action: onChooseFolder) { Label("Choose a Folder…", systemImage: "folder") }
                    .buttonStyle(.borderedProminent).accentedProminent().controlSize(.small)
                    .chromeHover()
                    .lockedDuringRun()
            }
            if best != nil, let onTryAnother {
                Button(action: onTryAnother) { Label("Try Another Folder", systemImage: "arrow.triangle.2.circlepath") }
                    .controlSize(.small)
                    .disabled(isTryAnotherBusy)
                    .help("Reject this folder and suggest a different one — remembered for next time")
            }
            if let onReadScan {
                Button(action: onReadScan) {
                    Label(isReadScanBusy ? "Reading…" : "Read Scan",
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
                Label("Set Aside", systemImage: "xmark")
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.hoverAffordance(.segment, tint: hueAccent)).controlSize(.small)
                .help("Set this suggestion aside — the file stays where it is, and the next scan can suggest it again")
        }
    }
}

// MARK: - Destination peek (G6)

/// Reads the "· N items" peek for a Filing destination off the render path, apart from the card so
/// its cancellation rule can be tested.
///
/// The card loads it from `.task(id: dest.path)`, which cancels when "Try another" swaps the
/// destination, but `Task.detached` doesn't inherit cancellation: a slow listing of the old folder
/// can finish after the new one, and without the check the card would show the old folder's count
/// under the new folder's name.
enum DestinationPeek {
    /// The number of visible (non-dot) entries in `path`, or nil when there is nothing to publish:
    /// unreadable, or superseded while listing. The caller must not write nil: when superseded,
    /// another read owns the field, and writing would blank a correct count.
    ///
    /// Contents not on this Mac are requested first, suspending (`waitForContents`): with the cloud
    /// app not running, a bare `contentsOfDirectory` never returns and strands a thread per card.
    /// Unanswered gives nil, as unreadable does.
    static func itemCount(atPath path: String, fileManager: FileManaging = FileManager.default) async -> Int? {
        // Not for "": `URL(fileURLWithPath:)` makes that the working directory.
        guard !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard await fileManager.waitForContents(of: url) else { return nil }
        let count = await Task.detached(priority: .utility) { () -> Int? in
            let listing = fileManager.listing(of: url)
            guard listing.outcome != .unreadable else { return nil }
            return listing.urls.filter { !$0.lastPathComponent.hasPrefix(".") }.count
        }.value
        // Checked after the await: the read is only stale once it has finished late. FileTreeView's
        // download-watch poll does the same after each detached lstat.
        guard !Task.isCancelled else { return nil }
        return count
    }
}
