import SwiftUI
import Design

// MARK: - The rail item

/// One item on Organize's lens rail: glyph, name, and a badge **only when there is something to
/// report**.
///
/// The two halves of the chips' argument are split here on purpose. The *place* is unconditional —
/// it is what pointed invocation ("Organize this folder") lands on, and what a badge cannot be
/// because a badge does not exist before a scan. The *claim* is conditional: `badge == nil` draws
/// no number at all, not a greyed one and not a `0`.
///
/// **It wears a capsule because a capsule is a control.** That rule came out of this very row: it
/// once carried six tinted capsules of which only three were buttons, and the only way to learn
/// which half was live was to click. Every rail item IS a button, and the readout still shares the
/// row with them after the divider — so dropping the capsule here would recreate the same
/// ambiguity from the other side, with live controls dressed as prose. The selected item deepens
/// its fill and adds the ring; the wash is what says "clickable" before you know which is current.
struct RailItemLabel: View {
    let title: String
    let systemImage: String
    let badge: Int?
    let isSelected: Bool
    let accent: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .scaledFont(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isSelected ? accent : Color.secondary)
            Text(title)
                .scaledFont(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                .fixedSize()
            if let badge {
                Text(badge, format: .number)
                    .scaledFont(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(accent.opacity(0.16)))
                    .fixedSize()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        // 0.14 is the `Pill` wash this row's other capsules use — matched deliberately, so the
        // rail reads as the same kind of thing rather than as a second, competing idiom.
        .background(Capsule().fill(accent.opacity(isSelected ? 0.22 : 0.14)))
        .overlay {
            if isSelected { Capsule().strokeBorder(accent, lineWidth: 2) }
        }
        .contentShape(Capsule())
    }
}

// MARK: - The overview

/// What one lens has to say for the current scope.
///
/// Three states, and the middle one is the one every previous version of this got wrong:
/// **absence must never be ambiguous between *clean* and *cannot run*.** A lens that has never
/// scanned says so and offers to; a lens that scanned and found nothing says *that*, quietly; only
/// a lens with findings takes a section.
enum OrganizeOverviewState: Equatable {
    /// Findings, with the headline number and an optional first example.
    case findings(count: Int, headline: String, example: String?)
    /// Ran, found nothing. Reported on the quiet trailing line rather than as a section.
    case clean
    /// Never ran here. Never rendered as a zero — a zero would be a claim this lens cannot make.
    case notScanned
}

/// One lens's contribution to the overview.
struct OrganizeOverviewSection: Identifiable {
    let lens: OrganizeLens
    let blurb: String
    let state: OrganizeOverviewState
    /// Whether this lens's answer is stale right now because the filing scan is republishing it.
    let isScanning: Bool

    var id: String { lens.rawValue }
}

/// Organize's landing: every lens's answer for the current scope, on one page.
///
/// **This is the rail's unselected state, not a seventh rail item.** That distinction is the whole
/// defence against the burial the chips were designed to avoid: a lens rail whose default landing
/// is one lens would leave the other five behind items you have to remember to visit. You land
/// here, so nothing has to be remembered — and clicking the selected rail item comes back.
///
/// Sections vanish at zero, exactly as the chips did. What replaces a vanished section is not
/// nothing: it is a line on the quiet footer saying the check ran, which is the difference between
/// "clean" and "never looked".
struct OrganizeOverview: View {
    let sections: [OrganizeOverviewSection]
    let scopeLabel: String?
    let accent: Color
    let onOpen: (OrganizeLens) -> Void
    let onScan: (OrganizeLens) -> Void

    private var reporting: [OrganizeOverviewSection] {
        sections.filter { if case .findings = $0.state { return true } else { return false } }
    }

    private var clean: [OrganizeOverviewSection] {
        sections.filter { $0.state == .clean }
    }

    private var unscanned: [OrganizeOverviewSection] {
        sections.filter { $0.state == .notScanned }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(reporting) { section in
                    sectionView(section)
                }
                if reporting.isEmpty {
                    allClearState
                }
                if !unscanned.isEmpty || !clean.isEmpty {
                    footer
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sectionView(_ section: OrganizeOverviewSection) -> some View {
        if case .findings(let count, let headline, let example) = section.state {
            findingsSection(section, count: count, headline: headline, example: example)
        }
    }

    private func findingsSection(_ section: OrganizeOverviewSection, count: Int,
                                 headline: String, example: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: section.lens.symbol)
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 21, height: 21)
                    .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(section.lens.title)
                        .scaledFont(.system(size: 12.5, weight: .semibold))
                    Text(section.blurb)
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(headline)
                    .scaledFont(.system(size: 12, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .fixedSize()
            }
            if let example {
                Text(example)
                    .scaledFont(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.leading, 30)
            }
            Button("Open \(section.lens.title) — \(count) ›") { onOpen(section.lens) }
                .buttonStyle(.plain)
                .scaledFont(.system(size: 11, weight: .semibold))
                .foregroundStyle(accent)
                .chromeHover()
                .padding(.leading, 30)
        }
    }

    /// Everything reporting is empty. Distinct from "nothing has run" — that lives in the footer.
    private var allClearState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(scopeLabel.map { "Nothing to do in \($0)." } ?? "Nothing to do here.")
                .scaledFont(.system(size: 12.5, weight: .semibold))
            Text("Every check that has run came back clean.")
                .scaledFont(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    /// The quiet line: what ran and was clean, and what has not run at all.
    ///
    /// The unscanned half carries its own **Scan…** rather than a shared button, because one
    /// button cannot honestly price five scans — duplicates means hashing and the rest ride one
    /// cheap pass.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            if !clean.isEmpty {
                Text(clean.map { "\($0.lens.title.lowercased()) checked" }
                        .joined(separator: " · "))
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            ForEach(unscanned) { section in
                HStack(spacing: 6) {
                    Text("\(section.lens.title) — not scanned")
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Button("Scan…") { onScan(section.lens) }
                        .buttonStyle(.plain)
                        .scaledFont(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent)
                        .chromeHover()
                }
            }
        }
    }
}
