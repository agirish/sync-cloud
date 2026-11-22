import Design
import SwiftUI
import Sync

/// What a row in Cards, List and People draws, from plain values only.
///
/// Equatable, and drawn `.equatable()`, so a change to the Vault that leaves a row as it was skips
/// that row. The panel reads one `ObservableObject`, so every publish (a read's progress, once per
/// document it opens) runs the panel's body again; with each row drawn inline, every row built so
/// far was drawn again too. Measured 2026-11-22 on 120 IDs, one publish fell from 13.4 to 8.6 ms
/// in People, 11.9 to 7.7 in Cards and 7.8 to 5.9 in List.
struct VaultRowLabel: View, Equatable {
    /// A mark beside the number: "Expired", "In use", "To confirm".
    struct Badge: Equatable {
        var text: String
        var tint: Color
    }

    enum Lead: Equatable {
        /// Under a person's name: the kind's symbol, in the card's own color.
        case kind(symbol: String, ink: Color)
        /// In Cards and List: whose it is, as a letter.
        case initials(String)
    }

    var lead: Lead
    var title: String
    var countryCode: String?
    var subtitle: String
    var masked: String
    var badges: [Badge]
    var isChosen: Bool
    var onColor: Bool

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.lead == b.lead && a.title == b.title && a.countryCode == b.countryCode && a.subtitle == b.subtitle
            && a.masked == b.masked && a.badges == b.badges && a.isChosen == b.isChosen && a.onColor == b.onColor
    }

    /// Counts this label's draws, for a test; nil in the app.
    @Environment(\.vaultDraws) private var draws

    var body: some View {
        let _ = draws?.rows.append(masked)
        HStack(spacing: 9) {
            switch lead {
            case .kind(let symbol, let ink):
                Image(systemName: symbol)
                    .scaledFont(.caption.weight(.semibold))
                    .foregroundStyle(ink)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: Radius.chip).fill(ink.opacity(0.16)))
                    .accessibilityHidden(true)
            case .initials(let letter):
                Text(letter)
                    .scaledFont(.caption.weight(.bold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.quaternary))
            }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(title)
                        .scaledFont(.body.weight(.semibold))
                        .lineLimit(1)
                    if let countryCode { Self.country(countryCode) }
                }
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(masked)
                    .scaledFont(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    ForEach(badges, id: \.text) { badge in Pill(.mini, tint: badge.tint, text: badge.text) }
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .modifier(VaultRowLift(isChosen: isChosen, onColor: onColor))
        .contentShape(Rectangle())
    }

    /// "US" or "IN" in a small box, beside a title or a value.
    static func country(_ code: String) -> some View {
        Text(code)
            .scaledFont(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(.quaternary))
            .accessibilityLabel(code == "US" ? "United States" : code == "IN" ? "India" : code)
    }
}

/// A whole row: its label, the click that chooses it, its right-click menu and what VoiceOver says.
///
/// Skipped while its row, its label, its spoken line and People are as they were (``==``), so a
/// publish that leaves a row alone builds nothing of it: not its button, its button style or its
/// menu. The menu observes the model itself, so a menu built at its first right-click still
/// follows whatever it reads beyond these (another ID to merge with, the kinds, a saved or waiting
/// ID).
struct VaultRow<Menu: View>: View, Equatable {
    let row: VaultModel.Row
    let label: VaultRowLabel
    let spoken: String
    /// Belongs To lists them, from the panel rather than the model.
    let people: [Person]
    let model: VaultModel
    let select: () -> Void
    @ViewBuilder let menu: (VaultModel.Row) -> Menu

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.label == b.label && a.spoken == b.spoken && a.people == b.people && a.model === b.model
    }

    /// Counts this row's draws, for a test; nil in the app.
    @Environment(\.vaultDraws) private var draws

    var body: some View {
        let _ = draws?.shells += 1
        Button(action: select) { label.equatable() }
            .buttonStyle(.plain)
            .contextMenu { VaultRowMenu(model: model, row: row, content: menu) }
            .accessibilityLabel(spoken)
            .accessibilityAddTraits(label.isChosen ? .isSelected : [])
    }
}

/// A row's menu, drawn again whenever the Vault changes, though its row is skipped.
struct VaultRowMenu<Content: View>: View {
    @ObservedObject var model: VaultModel
    let row: VaultModel.Row
    let content: (VaultModel.Row) -> Content

    var body: some View { content(row) }
}

/// A person's heading in People: their initial and name, how many IDs, Copy and Add ID.
///
/// Skipped while these are as they were (``==``); its actions find the person by `owner` when
/// they run, so a kept heading never acts on an older section.
struct VaultPersonHeader: View, Equatable {
    let owner: VaultPersonSection.Owner
    let title: String
    let subtitle: String
    /// "Copied" in place of "Copy" while one of this person's copies is on the clipboard.
    let copied: Bool
    let isAsking: Bool
    let copyHelp: String
    let copy: (_ numbers: Bool) -> Void
    let add: (_ person: String) -> Void

    /// Counts this heading's draws, for a test; nil in the app.
    @Environment(\.vaultDraws) private var draws

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.owner == b.owner && a.title == b.title && a.subtitle == b.subtitle && a.copied == b.copied
            && a.isAsking == b.isAsking && a.copyHelp == b.copyHelp
    }

    var body: some View {
        let _ = draws?.headers += 1
        HStack(spacing: 10) {
            Text(owner == .household ? "⌂" : String(title.prefix(1)).uppercased())
                .scaledFont(.callout.weight(.bold))
                .frame(width: 34, height: 34)
                .background(Circle().fill(.quaternary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .scaledFont(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            // One menu for both copies: a summary with endings, or every ID in full.
            Menu {
                Button("Copy Summary") { copy(false) }
                Button("Copy with Numbers…") { copy(true) }
            } label: {
                Text(copied ? "Copied" : "Copy")
            }
            .fixedSize()
            .help(copyHelp)
            if case .person(let id) = owner {
                Button {
                    add(id)
                } label: {
                    Label("Add ID", systemImage: "plus")
                }
                .help("Add an ID for \(title)")
            }
        }
        .controlSize(.small)
        .disabled(isAsking)
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }
}

/// How often a panel's rows and people's headings were drawn: a test's measure of what a change to
/// the Vault draws again. Given to one panel through its environment, so a test counts its own.
@MainActor final class VaultDrawCount {
    /// Each row drawn, by its number as masked, in order.
    var rows: [String] = []
    /// Rows whose button and menu were built again, label or not.
    var shells = 0
    var headers = 0
}

extension EnvironmentValues {
    @Entry var vaultDraws: VaultDrawCount? = nil
}
