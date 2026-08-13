import SwiftUI
import Sync

// MARK: - Learned-rule offer/review models
//
// The inline "teach a rule" flow that follows a filing move, extracted verbatim from TidyView
// (which owns the @State driving it — everything here is plumbed via explicit params/bindings,
// so the views stay dumb and the state machine stays in one place).

/// One pending "remember this override?" prompt (G2) — the loose file just filed and the folder it
/// went into, enough to seed an F3 rule. Identifiable so the inline prompt can animate in and out.
struct PendingRememberPrompt: Identifiable {
    let id = UUID()
    let fileName: String
    let destinationPath: String
}

/// One pending "save a rule?" offer — the file just filed and the proposed Automation for files like
/// it. Identifiable so the inline prompt animates in and out.
struct RuleOffer: Identifiable {
    let id = UUID()
    let fileName: String
    let proposal: AutomationRuleProposer.Proposal
}

// MARK: - Pure helpers

enum RuleOfferLogic {
    /// The destination folder as a path relative to the provider root (the rule's template is
    /// provider-relative). Falls back to the folder's leaf name when no root is known or the
    /// path lies outside it. The boundary math is Sync's `PathBoundary` (the one implementation
    /// of "inside the root?"); the standardizing pass and the leaf-name fallback stay here —
    /// they are this call site's policy, not the boundary rule's.
    static func relativeToProviderRoot(_ absolutePath: String, providerRoot: String?) -> String {
        guard let root = providerRoot, !root.isEmpty else {
            return (absolutePath as NSString).lastPathComponent
        }
        let r = (root as NSString).standardizingPath
        let p = (absolutePath as NSString).standardizingPath
        return PathBoundary.relativize(p, under: r) ?? (absolutePath as NSString).lastPathComponent
    }
}

// MARK: - Remember-override prompt

/// G2 — "Remember this for files like it?" The correction the user just made (filing into a
/// folder that wasn't the suggestion) is the strongest training signal, so surface it as a
/// visible, one-tap prompt rather than F3's easy-to-miss NSOpenPanel checkbox.
struct RememberOverridePromptView: View {
    let prompt: PendingRememberPrompt
    let accent: Color
    let onRemember: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        let folderName = (prompt.destinationPath as NSString).lastPathComponent
        return HStack(spacing: 10) {
            Image(systemName: "memories")
                .scaledFont(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Remember this for files like “\(prompt.fileName)”?")
                    .scaledFont(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text("File future matches into “\(folderName)” automatically — you’ll review it next; manage it anytime under Organize ▸ Rules.")
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Not now", action: onNotNow)
                .controlSize(.small)
            Button("Remember", action: onRemember)
                .buttonStyle(.borderedProminent)
                .chromeHover()
                .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(accent.opacity(0.28), lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Rule offer prompt

/// The inline "Save a rule?" offer after a filing move: the proposed rule with a compact picker
/// for how tightly to draw it, and the destination; Save creates an Automation.
///
/// **The picker offers phrasings, not condition types.** It used to be name / content / kind — three
/// unrelated single conditions, because that was all the proposer could produce. A proposal is now a
/// conjunction ("mentions *tmobile* and *autopay*"), and the choice worth offering is narrower
/// versus broader. The chips stay short (the row is three-across in a one-line prompt) and the
/// selected phrasing is spelled out in full underneath, so what Save will store is on screen.
struct RuleOfferPromptView: View {
    let offer: RuleOffer
    let accent: Color
    /// Which phrasing is selected — owned by the host so the choice survives this view being
    /// rebuilt and is readable at save time.
    @Binding var variantChoice: AutomationRuleProposer.Variant?
    let onSave: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        let variants = offer.proposal.variants
        let selected = variantChoice ?? offer.proposal.defaultVariant
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "wand.and.stars")
                .scaledFont(.system(size: 14, weight: .semibold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 6) {
                Text("Filed “\(offer.fileName)” → \(offer.proposal.destinationTemplate). Save a rule?")
                    .scaledFont(.system(size: 12, weight: .semibold))
                    .lineLimit(2).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text("Match:").scaledFont(.system(size: 11)).foregroundStyle(.secondary)
                    ForEach(variants) { variant in
                        let on = (selected == variant)
                        Button { variantChoice = variant } label: {
                            Text(variant.chipLabel)
                                .scaledFont(.system(size: 11, weight: on ? .semibold : .regular))
                                .lineLimit(1)
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                // 0.06 matches ConditionChip's quiet-chip wash (the app's one
                                // unselected-chip treatment).
                                .background(Capsule().fill(on ? accent.opacity(0.14) : Color.primary.opacity(0.06)))
                                .overlay(Capsule().strokeBorder(on ? accent.opacity(0.5) : Color.clear, lineWidth: 0.5))
                                .foregroundStyle(on ? accent : Color.secondary)
                        }
                        .buttonStyle(.hoverAffordance(on ? .filled : .segment, tint: accent))
                    }
                }
                // The sentence the chips abbreviate. A chip reading `“tmobile” + “autopay”` does not
                // say whether both words are required or either will do; this does.
                Text(selected.summary)
                    .scaledFont(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.tail)
            }
            Spacer(minLength: 8)
            VStack(spacing: 5) {
                Button("Save rule", action: onSave)
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    .chromeHover()
                Button("Not now", action: onNotNow)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(accent.opacity(0.28), lineWidth: 1))
        .padding(.horizontal, 12).padding(.top, 12)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
