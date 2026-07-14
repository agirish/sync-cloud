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

// MARK: - Name Normalizer lens

/// The Name Normalizer workspace: scans a provider subtree for cloud-hostile file & folder names,
/// previews the safe replacement for each, and normalizes them in one undoable pass. Rendered inside
/// ``TidyView``'s content card (which supplies the surface), so this view provides only the inner
/// intro / scanning / results / all-clean states — never its own card background.
public struct NameNormalizeLens: View {
    @ObservedObject public var syncManager: FileSyncManager

    @AppStorage(LiquidGlass.hueKey) private var glassHueRaw: String = LiquidGlassHue.blue.rawValue
    @AppStorage(ListDensity.defaultsKey) private var listDensityRaw: String = ListDensity.comfortable.rawValue

    /// Provider named in the intro copy (e.g. "OneDrive"). Falls back to a generic phrase.
    private let providerName: String?
    /// Kicks off a scan of the focused folder (host-supplied — it owns the root/provider derivation).
    private let onScanNames: () -> Void
    /// Applies the safe rename to the given rows as one undoable batch (host wires it to
    /// `syncManager.normalizeNames`).
    private let onNormalize: ([RiskyName]) -> Void

    public init(
        syncManager: FileSyncManager,
        providerName: String? = nil,
        onScanNames: @escaping () -> Void,
        onNormalize: @escaping ([RiskyName]) -> Void
    ) {
        self.syncManager = syncManager
        self.providerName = providerName
        self.onScanNames = onScanNames
        self.onNormalize = onNormalize
    }

    private var glassHue: LiquidGlassHue { LiquidGlassHue(rawValue: glassHueRaw) ?? .blue }
    private var densityMetrics: ListDensityMetrics {
        (ListDensity(rawValue: listDensityRaw) ?? .comfortable).metrics
    }
    private var provider: String { providerName ?? "this provider" }

    public var body: some View {
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

    // MARK: Intro / scanning / clean

    private var introState: some View {
        EmptyStateView(
            icon: NameNormalizeGlyph.lens,
            tint: glassHue.accentColor,
            title: "Find risky names in \(provider)",
            message: "Scan for file and folder names \(provider) can't sync — trailing spaces, forbidden characters, reserved names, and hidden invisible characters — then fix them all in one pass.",
            caption: "Nothing is renamed without your say-so, and every fix undoes with ⌘Z.",
            primary: .init("Scan for risky names", systemImage: NameNormalizeGlyph.lens, handler: onScanNames)
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
            secondary: .init("Scan again", systemImage: "arrow.clockwise", handler: onScanNames)
        )
    }

    // MARK: Results

    private var resultsState: some View {
        VStack(spacing: 0) {
            resultsHeader
            Divider().opacity(0.5)
            ScrollView {
                LazyVStack(spacing: densityMetrics.cardListSpacing) {
                    ForEach(syncManager.riskyNames) { risky in
                        RiskyNameCard(
                            risky: risky,
                            accent: glassHue.accentColor,
                            onFix: { onNormalize([risky]) },
                            onSkip: { syncManager.dismissRiskyName(risky) }
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
            Button(action: onScanNames) { Label("Rescan", systemImage: "arrow.clockwise") }
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
/// invisible characters made visible), the reason it's risky, and per-row Fix / Skip actions.
private struct RiskyNameCard: View {
    let risky: RiskyName
    let accent: Color
    let onFix: () -> Void
    let onSkip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                actions
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
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

    private var actions: some View {
        VStack(spacing: 6) {
            Button(action: onFix) {
                Label("Fix", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button(action: onSkip) {
                Text("Skip").frame(maxWidth: .infinity)
            }
            .controlSize(.small)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
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
