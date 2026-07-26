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
    @AppStorage(LiquidGlass.levelKey) private var glassLevelRaw: String = GlassLevel.frosted.rawValue
    /// The resolved glass material; `.frosted` (standard Liquid Glass) if unrecognized.
    private var glassLevel: GlassLevel { GlassLevel(rawValue: glassLevelRaw) ?? .frosted }
    @ObservedObject var syncManager: FileSyncManager
    /// The risky names to list — already filtered by the header card's search. The lens never
    /// reads `syncManager.riskyNames` for its list, so what's on screen is exactly what the header
    /// counted and what "Fix all N" acts on.
    let risky: [RiskyName]
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
            tint: SemanticColor.success,
            title: "No risky names — every name is cloud-safe",
            message: "Nothing in \(provider) would trip a cloud sync on its name. Scan again after adding files.",
            secondary: .init("Scan again", systemImage: "arrow.clockwise", handler: onScan)
        )
    }

    /// The list only. Its header row is gone — the shared LensHeaderCard above carries this lens's
    /// count, its Rescan / Fix all controls, and its search — which is what lets the workspace's
    /// header height be a promise rather than a per-lens accident.
    private var resultsState: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: densityMetrics.cardListSpacing) {
                    ForEach(risky) { risky in
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
                .animation(.easeInOut(duration: 0.22), value: risky.map(\.id))
            }
            .scrollContentBackground(.hidden)
        }
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
                    if densityMetrics.showsSecondaryDetail {
                        locationRow
                        renameRow
                        reasonRow
                    } else {
                        // Compact drops the visible reason line — keep the "why is this risky"
                        // reachable: a tooltip on the rename row, and the same text for VoiceOver.
                        // Combined first (the whyRow precedent): the rename row is a multi-element
                        // HStack, and an `.accessibilityValue` on an uncombined container may never
                        // be voiced because VO walks the children individually.
                        renameRow
                            .accessibilityElement(children: .combine)
                            .help(risky.reason)
                            .accessibilityValue(risky.reason)
                    }
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
                .foregroundStyle(SemanticColor.success)
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
                .chromeHover()
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

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(InvisibleNameMarking.cells(for: name).enumerated()), id: \.offset) { _, cell in
                if cell.isMarker { marker(cell.glyph) } else { Text(cell.glyph) }
            }
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .lineLimit(1)
    }

    /// Caution (yellow), not warning (orange): a risky name is a "needs your judgment" find —
    /// nothing was skipped or lost — matching the header's "risky names" pill so the whole
    /// risky-name vocabulary sits in one tier. Wash strength shares the pill fill token.
    private func marker(_ glyph: String) -> some View {
        Text(glyph)
            .foregroundStyle(SemanticColor.caution)
            .background(SemanticColor.caution.opacity(PillVariant.fillOpacity))
    }
}

/// Decides which scalars of a risky name get a visible marker — the rule behind
/// ``InvisibleMarkedName``, kept out of the view body so it can be tested. The view's entire job is
/// making an invisible character visible, so "which ones are marked" is the feature, not styling.
enum InvisibleNameMarking {
    /// One rendered cell: the glyph to draw, and whether it is a substituted marker (tinted) rather
    /// than the name's own character.
    struct Cell: Equatable {
        let glyph: String
        let isMarker: Bool
    }

    /// Zero-width / BOM scalars — invisible and NOT classed as whitespace, so they get an explicit
    /// marker wherever they sit. Mirrors ``NameNormalizer``'s set (kept local so the view doesn't
    /// depend on Sync internals).
    private static let zeroWidth: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0xFEFF]

    static func cells(for name: String) -> [Cell] {
        let scalars = Array(name.unicodeScalars)
        let edges = edgeWhitespaceIndices(scalars)
        return scalars.indices.map { idx in
            let scalar = scalars[idx]
            if zeroWidth.contains(scalar.value) {
                return Cell(glyph: "◌", isMarker: true)
            } else if scalar == " " {
                // An interior space is already visible by the text either side of it; only the
                // affix ones are the invisible surprise.
                return edges.contains(idx) ? Cell(glyph: "␣", isMarker: true) : Cell(glyph: " ", isMarker: false)
            } else if scalar.properties.isWhitespace {
                // No-break space, tab, other Unicode spaces — always suspicious in a name.
                return Cell(glyph: "␣", isMarker: true)
            } else {
                return Cell(glyph: String(scalar), isMarker: false)
            }
        }
    }

    /// Every index in the leading and trailing whitespace RUNS.
    ///
    /// Deliberately the whole run, not `idx == 0 || idx == count - 1`: "Swimming  " ends in two
    /// spaces, and marking only the outermost one drew a single "␣" followed by a space that was
    /// still invisible — so the name read as having one trailing space when it has two, in the one
    /// view whose whole job is making exactly that risk visible. Matches
    /// ``NameDisplay/visibleName(_:)``, which already walks the full run for the same reason.
    private static func edgeWhitespaceIndices(_ scalars: [Unicode.Scalar]) -> Set<Int> {
        var indices: Set<Int> = []
        var index = 0
        while index < scalars.count, scalars[index].properties.isWhitespace {
            indices.insert(index)
            index += 1
        }
        index = scalars.count - 1
        while index >= 0, scalars[index].properties.isWhitespace {
            indices.insert(index)
            index -= 1
        }
        return indices
    }
}
