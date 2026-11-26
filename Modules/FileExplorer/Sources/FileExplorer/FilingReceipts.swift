import SwiftUI
import Sync
import Design

/// What a filed, set-aside or trashed card leaves in its place for a moment (filing motion mockup):
/// what happened, where, and Undo. It waits unseen while its card is still on screen, takes the
/// card's place as the card leaves, holds, then folds away.
struct FilingReceipt: Identifiable, Equatable {
    enum Kind: Equatable { case filed, setAside, trashed, summary }

    let id = UUID()
    let kind: Kind
    /// The card it stands in for; nil for File All's summary, which sits at the top.
    let cardID: String?
    /// The section and place the card had.
    let section: FilingSectionKind
    let index: Int
    var text: String
    /// "Credit 44928 › 2026", set in the monospaced face after the text.
    var place: String?
    /// The undo step it can take back: Undo shows only while that is the step ⌘Z would take.
    var undoActionName: String?
    /// Set once the action has finished; the hold counts from here.
    var finished = false

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.text == b.text && a.place == b.place && a.finished == b.finished && a.undoActionName == b.undoActionName
    }

    /// How long a receipt stays before it folds: long enough to read and reach Undo.
    static let hold: Duration = .milliseconds(1600)
    /// File All's summary stays a while longer: it speaks for every card that went.
    static let summaryHold: Duration = .seconds(6)
}

/// A row of To File's list: a card, or a receipt standing where one was.
enum FilingListRow: Identifiable {
    case card(FilingCardItem)
    case receipt(FilingReceipt)

    var id: String {
        switch self {
        case .card(let item): return item.id
        case .receipt(let r): return "receipt:" + r.id.uuidString
        }
    }
}

enum FilingReceiptLayout {
    /// The section's rows with its receipts in place: each at the index its card had, and only once
    /// its card has left the list (until then the card itself says "Filing…"). A summary leads.
    static func rows(_ section: FilingCardSection, receipts: [FilingReceipt], allCardIDs: Set<String>) -> [FilingListRow] {
        var rows = section.items.map(FilingListRow.card)
        let mine = receipts.filter { $0.section == section.kind && ($0.cardID.map { !allCardIDs.contains($0) } ?? true) }
        for r in mine.filter({ $0.kind != .summary }).sorted(by: { $0.index < $1.index }) {
            rows.insert(.receipt(r), at: min(r.index, rows.count))
        }
        for r in mine where r.kind == .summary { rows.insert(.receipt(r), at: 0) }
        return rows
    }

    /// Receipts for sections that have no cards left, so the last card's receipt still shows.
    static func orphanSections(_ sections: [FilingCardSection], receipts: [FilingReceipt]) -> [FilingSectionKind] {
        let shown = Set(sections.map(\.kind))
        var out: [FilingSectionKind] = []
        for r in receipts where !shown.contains(r.section) && !out.contains(r.section) { out.append(r.section) }
        return out
    }

    /// "Filed 2 → Credit 44928 › 2026": the last two folders of where the files went.
    static func place(_ dest: FilingDestination, providerRoot: String?) -> String {
        FilingRouteText.movesTo(dest, providerRoot: providerRoot).crumbs.suffix(2).map(\.name).joined(separator: " › ")
    }
}

/// One receipt: a check, what happened and where, and Undo. Green for a filing, gray otherwise.
struct FilingReceiptView: View {
    let receipt: FilingReceipt
    let canUndo: Bool
    let onUndo: () -> Void
    let onHover: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    private var tint: Color { receipt.kind == .filed || receipt.kind == .summary ? SemanticColor.success : .secondary }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: receipt.kind == .trashed ? "trash.circle.fill" : receipt.kind == .setAside ? "minus.circle.fill" : "checkmark.circle.fill")
                .scaledFont(.system(size: 16))
                .foregroundStyle(tint)
                // The check settles in a beat after the receipt arrives.
                .scaleEffect(settled || reduceMotion ? 1 : 0.6)
                .opacity(settled || reduceMotion ? 1 : 0)
            (Text(receipt.text).foregroundStyle(.primary)
             + Text(receipt.place.map { " → " + $0 } ?? "").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary))
                .scaledFont(.system(size: 13))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            if canUndo {
                Button("Undo", action: onUndo)
                    .buttonStyle(.link)
                    .help("Put it back — the same as ⌘Z")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.well, style: .continuous).fill(tint.opacity(0.12)))
        .onHover(perform: onHover)
        .onAppear {
            withDesignAnimation(.spring(response: 0.32, dampingFraction: 0.72).delay(0.12), reduceMotion: reduceMotion) { settled = true }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(receipt.text + (receipt.place.map { ", " + $0 } ?? ""))
    }
}

/// "Filing…" with a small spinner, on a card's File button while its move runs.
struct FilingBusyLabel: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Filing…")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Filing")
    }
}
