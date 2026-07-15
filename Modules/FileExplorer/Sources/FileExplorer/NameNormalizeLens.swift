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

// MARK: - Risky names section

/// The risky-names results as an embeddable section — a header with a Fix-all action over a bounded,
/// scrolling list of cards — folded into the Organize lens. Unlike the retired standalone Name
/// Normalizer lens, it has no intro / scanning / all-clean states: the host shows it only when the
/// focused folder actually has risky names (surfaced by the cheap local scan Organize runs on open),
/// so a clean folder adds nothing to Organize.
struct RiskyNamesSection: View {
    @ObservedObject var syncManager: FileSyncManager
    let accent: Color
    let densityMetrics: ListDensityMetrics
    /// Applies the safe rename to the given rows as one undoable batch (host wires `normalizeNames`).
    let onNormalize: ([RiskyName]) -> Void
    /// Reveals the given absolute path in Finder (host owns the `NSWorkspace` call).
    let onReveal: (String) -> Void
    /// Quick Looks the file at the given absolute path. nil hides the per-row Preview button.
    let onQuickLook: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVStack(spacing: densityMetrics.cardListSpacing) {
                    ForEach(syncManager.riskyNames) { risky in
                        RiskyNameCard(
                            risky: risky,
                            accent: accent,
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
            // Bounded so a long list of risky names can't push the loose-files section off screen —
            // it scrolls within its own section instead.
            .frame(maxHeight: 300)
        }
    }

    private var header: some View {
        let count = syncManager.riskyNames.count
        return HStack(spacing: 8) {
            Image(systemName: NameNormalizeGlyph.risky)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text("\(count) name\(count == 1 ? "" : "s") may not sync")
                .font(.system(size: 12.5, weight: .semibold))
                .monospacedDigit()
            Text("· fix to keep them cloud-safe")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button(action: { onNormalize(syncManager.riskyNames) }) {
                Label("Fix all \(count)", systemImage: "checkmark.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(syncManager.isNormalizingNames)
            .help("Renames every risky name above to its cloud-safe form. Never overwrites an existing "
                  + "file, and the whole pass undoes with a single ⌘Z.")
        }
        .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
    }
}

// MARK: - Risky name row

/// One risky name rendered as a card: the item's location, its current name → safe replacement (with
/// invisible characters made visible), the reason it's risky, and a footer of actions — Preview /
/// Reveal to look before deciding, then Skip / Fix.
private struct RiskyNameCard: View {
    let risky: RiskyName
    let accent: Color
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
                    locationRow
                    renameRow
                    reasonRow
                }
                Spacer(minLength: 8)
            }
            actionsFooter
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private var locationRow: some View {
        let parent = (risky.relativePath as NSString).deletingLastPathComponent
        let kind = risky.isDirectory ? "folder" : "file"
        return Text(parent.isEmpty ? "\(kind) at the scan root" : "\(kind) in \(parent)")
            .font(.system(size: 10.5, design: .monospaced))
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
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
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
        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
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
