import SwiftUI
import Sync
import Design

/// One loose file as a Filing suggestion card, built like a group card (cards mockup v6): its name,
/// From and Moves to written out (the folders it would make marked), the reason, a confidence pill,
/// the file itself as a row to look at, and the actions.
struct FilingSuggestionCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let suggestion: FilingSuggestion
    /// Row measurements for the density setting, passed down by `LensWorkspaceView`, which reads
    /// the @AppStorage once.
    let densityMetrics: ListDensityMetrics
    let onFileHere: (FilingDestination) -> Void
    let onChooseFolder: () -> Void
    let onNotHere: () -> Void
    /// Reject the current folder and get a different suggestion. nil hides the button.
    var onTryAnother: (() -> Void)? = nil
    /// What Try Another said about this card: why it stayed on this Mac, why Claude did not answer
    /// (TE335). nil says nothing.
    var tryAnotherNote: FilingTryAnotherNote? = nil
    /// "Ask Claude with Page 1…", the click that sends this one file's first page to Claude from a
    /// folder that asks each time. nil hides it.
    var onAskClaudeWithPage: (() -> Void)? = nil
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
    /// Type the home in full ("Edit Path…"), offered on a home that creates folders. nil hides it.
    var pathEditor: FilingPathEditorHooks? = nil
    @State private var editingPath = false
    /// What Choose a Folder… would teach, for a statement; nil hides the row.
    var rememberAccount: FilingRememberAccount? = nil
    /// File Once Here, when the statement names other accounts too.
    /// Gets the home as shown, a typed folder name included.
    var onFileOnce: ((FilingPreference.Scope?, FilingDestination) -> Void)? = nil
    /// What filing copies into now, under the preferences as they stand.
    var copies: [FilingCopy] = []
    /// The folder the scan walked, which "From" is relative to.
    var scannedRoot: String? = nil
    /// What the file's row shows and does.
    var rowHooks = FilingFileRowsHooks()
    /// The list's own answer to "too narrow for the label column", so a card scrolled into view
    /// draws narrow from its first frame. nil measures the card itself.
    var isNarrow: Bool? = nil
    @State private var measuredNarrow = false
    private var narrow: Bool { isNarrow ?? measuredNarrow }

    /// The name typed into "Create as" over a proposed new folder, empty while untouched: the
    /// proposed name is the model's, not the user's, so they can change it before filing.
    ///
    /// Cleared whenever the destination changes. The card's identity is the suggestion, and "Try
    /// another" swaps the destination under it, so a stale name would be applied to the next one.
    ///
    /// Held by the list when it passes `typedFolderName`, so File All files under the typed name too.
    var typedFolderName: Binding<String>? = nil
    @State private var localFolderName = ""
    private var folderName: Binding<String> { typedFolderName ?? $localFolderName }
    private var editedFolderName: String { folderName.wrappedValue }

    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    private var hueAccent: Color { (LiquidGlassHue(rawValue: glassHueRaw) ?? .blue).accentColor }

    private var best: FilingDestination? { suggestion.best }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(suggestion.fileName)
                        .scaledFont(.system(size: 14, weight: .semibold))
                        .lineLimit(2).truncationMode(.middle)
                        // Compact hides the "why" line; its words stay a hover and VoiceOver away.
                        .help(densityMetrics.showsSecondaryDetail ? "" : best.flatMap(rationale) ?? "")
                        .accessibilityValue(densityMetrics.showsSecondaryDetail ? "" : best.flatMap(rationale) ?? "")
                    FilingRouteGrid(lines: FilingRouteText.lines(members: [suggestion], destination: best,
                                                                 scannedRoot: scannedRoot, copies: copies),
                                    narrow: narrow, accent: hueAccent)
                    if densityMetrics.showsSecondaryDetail, let best { whyRow(best) }
                    // Never hidden by density: it says the tree already has this document, so
                    // "File here" would make a second copy.
                    if suggestion.isAlreadyFiled { alreadyFiledRow }
                    if let twin = suggestion.duplicateOf {
                        Label("A copy of “\((twin as NSString).lastPathComponent)” in this list — file that one", systemImage: "doc.on.doc")
                            .scaledFont(.system(size: 11))
                            .foregroundStyle(SemanticColor.caution)
                    }
                    if isNotDownloaded { notDownloadedRow }
                    if best?.remembered == true { rememberedBadge }
                    else if best?.fromAI == true { aiBadge }
                    if let note = tryAnotherNote { tryAnotherNoteRow(note) }
                    if let best, FilingRouteText.offersCreateAs(best) { newFolderNameField(best) }
                }
                Spacer(minLength: 8)
                FilingConfidencePill(confidence: best?.confidence)
            }
            Divider()
            FilingFileRows(members: [suggestion], inGroup: false, narrow: narrow, accent: hueAccent, hooks: rowHooks)
            actions
            if let rememberAccount { FilingRememberAccountRow(remember: rememberAccount) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, max(densityMetrics.cardHeaderVerticalPadding, 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: Bool.self) { $0.size.width < FilingGroupCard.narrowWidth } action: { measuredNarrow = $0 }
        .lensCard()
        // The typed name belongs to the destination it was typed for: "Try another" swaps `best`
        // under this card and `@State` survives. Keyed on the proposed leaf, the string the field
        // edits, so the same name under a different parent keeps what the user typed.
        .onChange(of: best?.newSegments.last) { _, _ in folderName.wrappedValue = "" }
        .popover(isPresented: $editingPath, arrowEdge: .bottom) {
            if let pathEditor {
                FilingPathEditor(hooks: pathEditor) { editingPath = false }
                    .presentedNativeControlAccent()
            }
        }
    }

    /// What Try Another said, under the card's reason: a sentence, and where it applies the click that
    /// sends this file's page to Claude. The first page is sent only on that click.
    private func tryAnotherNoteRow(_ note: FilingTryAnotherNote) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label { Text(note.text).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "info.circle") }
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
            if note.offersClaudeWithPage, let onAskClaudeWithPage {
                Button("Ask Claude with Page 1…", action: onAskClaudeWithPage)
                    .buttonStyle(.link).controlSize(.small)
                    .disabled(isTryAnotherBusy)
                    .help("Sends this file’s first page to Claude, once, to ask for another folder. It is billed to your API key and counts against Ask Claude’s monthly limit.")
            }
        }
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

    /// An editable name for the folder that would be created. Only for a new destination: renaming an
    /// existing one would propose a different folder (``FilingDestination/renamingNewFolder(to:)``
    /// refuses that).
    @ViewBuilder
    private func newFolderNameField(_ dest: FilingDestination) -> some View {
        if let leaf = dest.newSegments.last {
            HStack(spacing: 6) {
                if dest.newSegments.count == 1 {
                    // One new level: its name can be changed in place.
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .scaledFont(.system(size: 11)).foregroundStyle(hueAccent)
                        Text("Create as").scaledFont(.system(size: 12)).foregroundStyle(.secondary)
                        TextField(leaf, text: folderName)
                            .textFieldStyle(.roundedBorder)
                            .scaledFont(.system(size: 12))
                            .frame(maxWidth: 220)
                            .help("The name of the folder that will be created. Leave it to accept “\(leaf)”.")
                            .accessibilityLabel("Create the folder as")
                    }
                    // The field stays its own element, so VoiceOver can edit it.
                    .accessibilityElement(children: .contain)
                } else {
                    // Several: renaming the last alone would leave the others unseen.
                    HStack(spacing: 6) {
                        Image(systemName: "folder.badge.plus")
                            .scaledFont(.system(size: 11)).foregroundStyle(hueAccent)
                        Text(FilingPathEditorText.preview(dest))
                            .scaledFont(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
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

    /// The action row: every button while the card is wide enough, and below that File Here and
    /// Choose a Folder… with the rest in a ⋯ menu, so the row never outgrows a narrow workspace
    /// (the pinned Ask Claude column leaves To File about 340 to 640 pt). `ViewThatFits` takes the
    /// first row that fits, so the break moves with the text size.
    @ViewBuilder
    var actions: some View {
        ViewThatFits(in: .horizontal) {
            actionRow(compact: false)
            actionRow(compact: true)
        }
    }

    /// One row of actions: the full set, or the two that matter with the others behind ⋯.
    func actionRow(compact: Bool) -> some View {
        HStack(spacing: 9) {
            primaryButtons
            if compact {
                overflowMenu
                fileOnceMenu
            } else {
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
                    .help(Self.readScanHelp)
                }
                if pathEditor != nil {
                    Button("Edit Path…") { editingPath = true }
                        .controlSize(.small)
                        .help("Type where it goes, anywhere in your folders; missing folders are made when you file")
                }
                fileOnceMenu
                setAsideButton
            }
        }
    }

    private static let readScanHelp = "This PDF has no text layer, so the suggestion was made from its name alone. "
        + "Read it with OCR and suggest again — a second or two."

    /// File Here and Choose a Folder…, or Choose a Folder… alone where there is no confident home.
    @ViewBuilder
    private var primaryButtons: some View {
        if let best, suggestion.hasConfidentHome {
            // The typed name, when the user typed one — see `newFolderNameField`.
            Button { onFileHere(best.renamingNewFolder(to: editedFolderName)) } label: {
                Label(best.createsAccountFolder ? "Create and File" : "File Here", systemImage: "arrow.right.circle")
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
    }

    /// File Once Here, beside File Here, when the statement names other accounts too.
    @ViewBuilder
    private var fileOnceMenu: some View {
        if let onFileOnce, let best, !copies.isEmpty {
            FilingFileOnceMenu(copies: copies) { onFileOnce($0, best.renamingNewFolder(to: editedFolderName)) }
        }
    }

    private var setAsideButton: some View {
        Button(action: onNotHere) {
            Label("Set Aside", systemImage: "xmark")
                .padding(.horizontal, 6).padding(.vertical, 2)
                .contentShape(Rectangle())
        }
            .buttonStyle(.hoverAffordance(.segment, tint: hueAccent)).controlSize(.small)
            .help("Set this suggestion aside — the file stays where it is, and the next scan can suggest it again")
    }

    /// The buttons a narrow card puts away: the same actions, as menu items.
    private var overflowMenu: some View {
        Menu {
            if best != nil, let onTryAnother {
                Button(action: onTryAnother) { Label("Try Another Folder", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(isTryAnotherBusy)
            }
            if let onReadScan {
                Button(action: onReadScan) {
                    Label(isReadScanBusy ? "Reading…" : "Read Scan", systemImage: "text.viewfinder")
                }
                .disabled(isReadScanBusy)
            }
            if pathEditor != nil { Button("Edit Path…") { editingPath = true } }
            Divider()
            Button(action: onNotHere) { Label("Set Aside", systemImage: "xmark") }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .controlSize(.small)
        .fixedSize()
        .help("More: Try Another Folder, Read Scan, Edit Path and Set Aside")
        .accessibilityLabel("More actions")
    }
}
