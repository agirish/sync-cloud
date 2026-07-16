import SwiftUI
import Sync
import Design

// MARK: - Name Normalizer glyph vocabulary

/// The Name Normalizer lens's own iconography, kept distinct from the duplicate finder's
/// (`wand.and.stars` / `checkmark.seal.fill`) and Filing's (`folder.badge.gearshape` / trays) so the
/// three lenses never share a symbol.
enum NameNormalizeGlyph {
    /// Signature symbol — text with a warning, for the intro and per-row markers.
    static let lens = "textformat.abc.dottedunderline"
    /// Earned all-clean terminal state: every name is cloud-safe. A shield, deliberately not the
    /// duplicate finder's seal.
    static let allSafe = "checkmark.shield.fill"
    /// The per-row "this name is risky" marker.
    static let risky = "exclamationmark.triangle.fill"
}

// MARK: - Rename lens

/// The "Rename" lens (the former Name Normalizer): scans one provider subtree for cloud-hostile file
/// & folder names, previews the safe replacement for each, and fixes them in one undoable pass.
/// Its own intro / scanning / results / all-clean states; rendered inside ``TidyView``'s content card.
struct RenameLens: View {
    @ObservedObject var syncManager: FileSyncManager
    let providerName: String?
    let accent: Color
    let densityMetrics: ListDensityMetrics
    /// Kicks off a scan of the focused folder (host owns the root/provider derivation).
    let onScan: () -> Void
    /// Applies the safe rename to the given rows as one undoable batch (host wires `normalizeNames`).
    let onNormalize: ([RiskyName]) -> Void
    /// Reveals the given absolute path in Finder (host owns the `NSWorkspace` call).
    let onReveal: (String) -> Void
    /// Quick Looks the file at the given absolute path. nil hides the per-row Preview button.
    let onQuickLook: ((String) -> Void)?

    private var provider: String { providerName ?? "this provider" }

    var body: some View {
        Group {
            if syncManager.isScanningNames {
                scanningState
            } else if !syncManager.hasScannedNames {
                introState
            } else if syncManager.riskyNames.isEmpty {
                cleanState
            } else {
                resultsState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var introState: some View {
        EmptyStateView(
            icon: NameNormalizeGlyph.lens,
            tint: accent,
            title: "Find risky names in \(provider)",
            message: "Scan for file and folder names \(provider) can't sync — trailing spaces, forbidden characters, reserved names, and hidden invisible characters — then fix them all in one pass.",
            caption: "Nothing is renamed without your say-so, and every fix undoes with ⌘Z.",
            primary: .init("Scan for risky names", systemImage: NameNormalizeGlyph.lens, handler: onScan)
        )
    }

    private var scanningState: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text(syncManager.nameScanStatus.isEmpty ? "Scanning…" : syncManager.nameScanStatus)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button("Cancel") { syncManager.cancelNameScan() }
                .controlSize(.regular)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private var cleanState: some View {
        EmptyStateView(
            icon: NameNormalizeGlyph.allSafe,
            tint: .green,
            title: "No risky names — every name is cloud-safe",
            message: "Nothing in \(provider) would trip a cloud sync on its name. Scan again after adding files.",
            secondary: .init("Scan again", systemImage: "arrow.clockwise", handler: onScan)
        )
    }

    private var resultsState: some View {
        VStack(spacing: 0) {
            resultsHeader
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(spacing: densityMetrics.cardListSpacing) {
                    ForEach(syncManager.riskyNames) { risky in
                        RiskyNameCard(
                            risky: risky,
                            accent: accent,
                            densityMetrics: densityMetrics,
                            onFix: { onNormalize([risky]) },
                            onSkip: { syncManager.dismissRiskyName(risky) },
                            onReveal: { onReveal(risky.id) },
                            onPreview: onQuickLook.map { ql in { ql(risky.id) } }
                        )
                        .transition(.asymmetric(insertion: .identity,
                                                removal: .opacity.combined(with: .move(edge: .leading))))
                    }
                }
                .padding(densityMetrics.cardListPadding)
                .animation(.easeInOut(duration: 0.22), value: syncManager.riskyNames.map(\.id))
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var resultsHeader: some View {
        let count = syncManager.riskyNames.count
        return HStack(spacing: 10) {
            Image(systemName: NameNormalizeGlyph.risky)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            Text("\(count) risky name\(count == 1 ? "" : "s") found")
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
            Text("→ review & fix in one pass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button(action: onScan) { Label("Rescan", systemImage: "arrow.clockwise") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(syncManager.isNormalizingNames)
                .help("Scan the focused folder again")
            Button(action: { onNormalize(syncManager.riskyNames) }) {
                Label("Fix all \(count)", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(syncManager.isNormalizingNames)
            .help("Renames every risky name above to its cloud-safe form. Never overwrites an existing "
                  + "file, and the whole pass undoes with a single ⌘Z.")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: - Risky name row

/// One risky name rendered as a card: the item's location, its current name → safe replacement (with
/// invisible characters made visible), the reason it's risky, and a footer of actions — Preview /
/// Reveal to look before deciding, then Skip / Fix.
private struct RiskyNameCard: View {
    let risky: RiskyName
    let accent: Color
    /// Row measurements per the appearance density setting (D4). Comfortable must render this card
    /// pixel-identical to the pre-density look.
    let densityMetrics: ListDensityMetrics
    let onFix: () -> Void
    let onSkip: () -> Void
    /// Reveal this item in Finder.
    let onReveal: () -> Void
    /// Quick Look the file. nil hides the Preview button (e.g. no presenter wired).
    var onPreview: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: FileIconCache.icon(name: risky.currentName, isDirectory: risky.isDirectory))
                    .resizable().frame(width: 26, height: 26)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    // The location and reason lines are the secondary detail compact hides (D4);
                    // the rename row still shows the risky name (markers included) and its fix.
                    if densityMetrics.showsSecondaryDetail { locationRow }
                    renameRow
                    if densityMetrics.showsSecondaryDetail { reasonRow }
                }
                Spacer(minLength: 8)
            }
            actionsFooter
        }
        .padding(.horizontal, 14).padding(.vertical, densityMetrics.cardHeaderVerticalPadding)
        .lensCard()
    }

    private var locationRow: some View {
        let parent = (risky.relativePath as NSString).deletingLastPathComponent
        let kind = risky.isDirectory ? "folder" : "file"
        return Text(parent.isEmpty ? "\(kind) at the scan root" : "\(kind) in \(parent)")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.tertiary)
            .lineLimit(1).truncationMode(.middle)
    }

    private var renameRow: some View {
        HStack(spacing: 8) {
            InvisibleMarkedName(name: risky.currentName)
                .foregroundStyle(.primary)
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.tertiary)
            Text(risky.sanitizedName)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.green)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    private var reasonRow: some View {
        Text(risky.reason)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    /// One footer row of labeled, comfortably-sized buttons. Read-only "look before you act"
    /// utilities (Preview / Reveal) sit on the left; the decision (Skip / Fix, Fix prominent) sits on
    /// the right. A single labeled action zone reads far cleaner — and each target is far easier to
    /// hit — than a corner cluster of tiny icon glyphs, and it mirrors the sibling Filing card's
    /// footer. Preview and Reveal touch nothing, so they stay usable while a batch fix runs.
    private var actionsFooter: some View {
        HStack(spacing: 9) {
            if let onPreview {
                Button(action: onPreview) { Label("Preview", systemImage: "eye") }
                    .help("Quick Look this \(itemKind) — click again, or press Space/Esc, to close")
            }
            Button(action: onReveal) { Label("Reveal", systemImage: RevealGlyph.inFinder) }
                .help("Show this \(itemKind) in Finder")
            Spacer(minLength: 12)
            Button("Skip", action: onSkip)
            Button(action: onFix) { Label("Fix", systemImage: "checkmark") }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
    }

    private var itemKind: String { risky.isDirectory ? "folder" : "file" }
}

// MARK: - Invisible-marked name

/// Renders a name with its invisible / risky characters made visible: edge (leading/trailing) spaces
/// and any non-standard whitespace become a visible open-box "␣", and zero-width / BOM scalars become
/// a dotted-circle "◌" — so a trailing space or a hidden joiner isn't an invisible surprise. The
/// substituted markers are tinted so the eye lands on exactly what makes the name risky.
private struct InvisibleMarkedName: View {
    let name: String

    /// Zero-width / BOM scalars — invisible and NOT classed as whitespace, so they get an explicit
    /// marker. Mirrors ``NameNormalizer``'s set (kept local so the view doesn't depend on Sync
    /// internals).
    private static let zeroWidth: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0xFEFF]

    var body: some View {
        let scalars = Array(name.unicodeScalars)
        return HStack(spacing: 0) {
            ForEach(Array(scalars.enumerated()), id: \.offset) { idx, scalar in
                segment(for: scalar, isEdge: idx == 0 || idx == scalars.count - 1)
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }

    @ViewBuilder
    private func segment(for scalar: Unicode.Scalar, isEdge: Bool) -> some View {
        if Self.zeroWidth.contains(scalar.value) {
            marker("◌")
        } else if scalar == " " {
            if isEdge { marker("␣") } else { Text(" ") }
        } else if scalar.properties.isWhitespace {
            // No-break space, tab, other Unicode spaces — always suspicious in a name.
            marker("␣")
        } else {
            Text(String(scalar))
        }
    }

    private func marker(_ glyph: String) -> some View {
        Text(glyph)
            .foregroundStyle(.orange)
            .background(Color.orange.opacity(0.16))
    }
}
