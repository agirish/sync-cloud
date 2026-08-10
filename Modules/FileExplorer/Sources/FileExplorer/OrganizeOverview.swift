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
/// What a rail item has to say about its lens, and therefore how it is dressed.
///
/// **The same three states ``OrganizeOverviewState`` models, deliberately.** The overview is
/// careful never to conflate *ran and found nothing* with *never looked* — a zero would be a claim
/// a lens that has not scanned cannot make — and the rail used to throw that distinction away,
/// drawing both as an item with no badge. Two surfaces describing one set of facts had two
/// vocabularies; now they have one, and `TidyView` derives both from the same counts.
enum RailItemState: Equatable {
    /// This lens has findings here. The count is the whole scoped list, never the filtered view.
    case reporting(Int)
    /// It ran and found nothing. Says so by going quiet, not by drawing a `0`.
    case clean
    /// It has not run here at all. Never a zero — that would be a claim it cannot support.
    case notScanned
    /// Not a finding at all: Rules is configuration you keep. It never reports and never goes
    /// quiet, so it is neither `clean` nor `notScanned` — those both describe a scan.
    case configuration
}

/// One item on Organize's lens rail: glyph, name, and a badge **only when there is something to
/// report**.
///
/// The two halves of the chips' argument are split here on purpose. The *place* is unconditional —
/// it is what pointed invocation ("Organize this folder") lands on, and what a badge cannot be
/// because a badge does not exist before a scan. The *claim* is conditional: nothing to report
/// draws no number at all, not a greyed one and not a `0`.
///
/// **It wears a capsule because a capsule is a control.** That rule came out of this very row: it
/// once carried six tinted capsules of which only three were buttons, and the only way to learn
/// which half was live was to click. Every rail item IS a button, so dropping the capsule on the
/// quiet ones would recreate that ambiguity from the other side, with live controls dressed as
/// prose.
///
/// ## The tint says "has work", not "is clickable"
///
/// Every item used to wear the same `accent.opacity(0.14)` whether it had found 722 things or
/// nothing at all, so the only signal was a small badge at the item's tail and the row read as six
/// identical capsules. The capsule still carries the control claim; the *wash* now carries the
/// finding. A reporting item is accent-tinted with an accent glyph; a quiet one takes a neutral
/// wash and a secondary glyph. Both are plainly buttons, and which two of the six want you is
/// legible before you read a single number.
struct RailItemLabel: View {
    let title: String
    let systemImage: String
    let state: RailItemState
    let isSelected: Bool
    let accent: Color
    /// Whether the row can afford this item's label — see ``OrganizeRailMetrics``. At `.iconOnly`
    /// the name survives in the tooltip and the accessibility label, exactly as the workspace
    /// bar's segments do when they shed.
    var style: OrganizeRailStyle = .full

    /// Findings — the one state that colours the item.
    private var isReporting: Bool {
        if case .reporting = state { return true }
        return false
    }

    /// The badge's digits, abbreviated past three of them.
    ///
    /// `count.formatted()` puts the separator in, so the rename backlog's badge reads `1,192` and
    /// measures 40.9pt against 16.8 for a single digit. The rail is widest on the day every finding
    /// reports, which is the day it most needs to fit — and a four-digit badge also shouts over a
    /// `3` on Names that may matter far more, because a badge encodes list size and never urgency.
    /// Abbreviating buys back 7.5pt, which is small; the reason to do it is the shouting. The exact
    /// figure stays in the tooltip and in row 2's readout.
    /// `nonisolated` because ``OrganizeRailMetrics`` measures this string, and that model is a pure
    /// type the width arithmetic calls off the main actor. A `View`'s static members inherit
    /// `@MainActor`, so without this the one caller that must agree with the drawn text cannot
    /// reach it — and the tempting fix, restating the rule in the model, is exactly the divergence
    /// this whole type exists to prevent.
    nonisolated static func badgeText(_ count: Int) -> String {
        guard count >= 1000 else { return count.formatted() }
        let thousands = Double(count) / 1000
        return thousands >= 10
            ? "\(Int(thousands.rounded(.down)))k"
            : String(format: "%.1fk", (thousands * 10).rounded(.down) / 10)
    }

    /// What VoiceOver reads for one rail item: its name, then what it has to say.
    ///
    /// Pure and static so the composition can be asserted without an assistive client attached —
    /// this suite has no accessibility tree to read back, so a caption assertion made against the
    /// live view would pass vacuously whatever the label said.
    ///
    /// **The count is spoken in full**, not abbreviated: `1.2k` is a width compromise the row makes
    /// because six capsules share it, and a spoken label has no such constraint. "1,192" is what
    /// the list actually holds.
    nonisolated static func accessibilityLabel(title: String, state: RailItemState) -> String {
        switch state {
        case .reporting(let count):
            return "\(title), \(count.formatted())"
        case .clean:
            return "\(title), nothing found"
        case .notScanned:
            return "\(title), not scanned"
        case .configuration:
            // Rules and the overview item. Neither reports, so neither has a state to announce —
            // and appending "nothing found" to Rules would be the same lie the badge refuses to
            // tell by never drawing a zero there.
            return title
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .scaledFont(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(isSelected || isReporting ? accent : Color.secondary)
            if style == .full {
                Text(title)
                    .scaledFont(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .fixedSize()
            }
            switch state {
            case .reporting(let count):
                Text(Self.badgeText(count))
                    .scaledFont(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(accent.opacity(0.16)))
                    .fixedSize()
            case .notScanned:
                // Not a zero, and not nothing either: a lens that has never run here is a different
                // fact from one that ran and came back clean, and the row is the only place that
                // difference is visible without opening the lens. The tooltip says it in words.
                Circle()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 4, height: 4)
            case .clean, .configuration:
                EmptyView()
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        // **The state has to be spoken, because the state is carried in colour.** This said the
        // title and nothing else, which was survivable while every item looked alike and the only
        // extra information was a badge. It is not survivable now: a reporting item is told apart
        // from a quiet one by its *tint*, and an unscanned one from a clean one by a 4pt dot —
        // neither of which reaches VoiceOver, so all six items announced identically and the whole
        // point of the row was invisible. Colour alone must never be the only carrier of a state
        // (the same rule the scan-freshness pill follows, where `ScanFreshness` supplies a spoken
        // form saying "may be out of date" outright).
        .accessibilityLabel(Self.accessibilityLabel(title: title, state: state))
        // 0.14 is the `Pill` wash this row's other capsules use — matched deliberately, so a
        // reporting item reads as the same kind of thing rather than as a second, competing idiom.
        // The quiet rungs drop to a neutral fill of the same weight, which keeps the capsule (and
        // so the control claim) while spending no colour on a lens with nothing to say.
        .background {
            if isReporting || isSelected {
                Capsule().fill(accent.opacity(isSelected ? 0.22 : 0.14))
            } else {
                Capsule().fill(Color.secondary.opacity(0.10))
            }
        }
        .overlay {
            if isSelected { Capsule().strokeBorder(accent, lineWidth: 2) }
        }
        .contentShape(Capsule())
    }
}

// MARK: - The scope chip

/// The one chip naming what Organize is answering about.
///
/// **A view of its own rather than a `@ViewBuilder` inside `TidyView`, so it can be rendered and
/// read back.** That is not a stylistic preference: this row has already truncated its contents to
/// identical stubs once, and four tests compared those stubs and saw no difference — the header's
/// trailing controls clipped, nothing logged, and a probe that only asked whether the band was
/// *inked* saw nothing wrong. Ink presence is not label fidelity. Rendering this in isolation is
/// what lets `OrganizeScopeChipTests` assert the label really says what it claims.
///
/// It names the subtree **and its folder count**, because scope honesty was the original
/// requirement: "Legal" says which folder but not how much of the tree that is, and the count is
/// what makes a lens reporting zero legible as a real answer rather than a broken lens.
struct ScopeChipLabel: View {
    let name: String
    /// Folders inside the scope, or nil when there is no profile to count against.
    let folderCount: Int?
    let accent: Color
    let onClear: () -> Void

    /// The count's words, factored out so a test can assert the string without reading pixels for
    /// the parts that pixels are a poor instrument for.
    static func folderCountText(_ count: Int) -> String {
        "\(count) folder\(count == 1 ? "" : "s")"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "scope")
                .scaledFont(.system(size: 9.5, weight: .semibold))
            Text(name)
                .scaledFont(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            if let folderCount {
                Text(Self.folderCountText(folderCount))
                    .scaledFont(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .scaledFont(.system(size: 8.5, weight: .bold))
            }
            .buttonStyle(.plain)
            .chromeHover()
            .help("Organize everything again")
            .accessibilityLabel("Clear scope")
        }
        .foregroundStyle(accent)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(accent.opacity(0.14)))
        // `fixedSize` so the chip keeps its natural width rather than being compressed into an
        // ellipsis by whatever shares its row — a truncated scope name is a scope claim you cannot
        // read, which is worse than one that pushes the readout beside it.
        .fixedSize()
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
    /// The loose-files inbox offered as a **visible scope shortcut**, or nil when there is no inbox
    /// folder (or it is already the scope).
    ///
    /// This is what replaced the hidden root-swap. `filingScanTargetFolder` used to retarget To
    /// File to the inbox silently whenever the pane happened to sit at the provider root — a
    /// browsing accident deciding the subject. Now it is a thing you can see and click, and because
    /// the scope is sticky across launches it is clicked once rather than re-implied every session.
    ///
    /// **Not the default scope.** Scoped to `TODO`, Renames falls from 126 folders to 0 and five of
    /// the six lenses go dark on launch: the inbox is the right subject for To File and the wrong
    /// one for everything else.
    var inboxShortcut: InboxShortcut?

    struct InboxShortcut {
        /// The inbox's leaf name — "TODO" unless the setting was changed.
        let name: String
        /// Loose files sitting in it, or **nil when the last scan did not cover the inbox** and the
        /// number is therefore unknown.
        ///
        /// Optional because the count comes from one scan's published queue: scoped elsewhere, or
        /// before any scan, nothing in that list is under the inbox and the offer claimed "0 loose
        /// files" while the inbox held fifty — talking the user out of the very click this control
        /// exists to offer. Absent beats a wrong zero, exactly as the rail badges have it.
        let looseFileCount: Int?
        let apply: () -> Void
    }

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
                if let inboxShortcut { inboxOffer(inboxShortcut) }
                if !unscanned.isEmpty || !clean.isEmpty {
                    footer
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The offer's second line: the count when it is known, and the invitation alone when it is not.
    ///
    /// A value rather than a ternary in the body so it can be asserted without rendering — the
    /// wrong-zero it replaces was a string, and strings are what this needs to pin.
    static func inboxSubtitle(_ looseFileCount: Int?) -> String {
        guard let n = looseFileCount else { return "Organize just this folder" }
        return n == 1
            ? "1 loose file — organize just this folder"
            : "\(n) loose files — organize just this folder"
    }

    /// "Inbox (TODO) — N loose files", one click to scope there.
    ///
    /// Placed after the findings and before the quiet footer: it is an offer about where to look
    /// next, not a finding, and putting it above the sections would give the inbox the prominence
    /// the old hidden default gave it — which is the thing being undone.
    private func inboxOffer(_ shortcut: InboxShortcut) -> some View {
        Button(action: shortcut.apply) {
            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .scaledFont(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 21, height: 21)
                    .background(RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Inbox (\(shortcut.name))")
                        .scaledFont(.system(size: 12.5, weight: .semibold))
                    Text(Self.inboxSubtitle(shortcut.looseFileCount))
                        .scaledFont(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .scaledFont(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accent)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .chromeHover()
        .help("Point Organize at the inbox. Every lens narrows to it, and it stays until you "
              + "change it.")
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
