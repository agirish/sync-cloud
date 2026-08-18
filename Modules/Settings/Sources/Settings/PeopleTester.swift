import Design
import Sync
import SwiftUI

/// Type a filename, see who Organize would say it belongs to — and what that decides.
///
/// **The section could describe the rule but not demonstrate it.** Everything above this reports
/// state: these names, those folders, that many documents. None of it shows the rule *running*,
/// which is the thing the user is actually being asked to trust — and the interesting behaviour is
/// counter-intuitive enough to be worth watching: "Aditi Abhishek" naming one person rather than
/// two only makes sense once you have seen it happen.
///
/// Answers come from ``PersonRegistry/explain(in:)``, which is the same call `detect` is built on,
/// so this cannot drift into agreeing with a rule the engine does not have.
struct PeopleTester: View {
    let registry: PersonRegistry
    let factsById: [String: PersonFilingFacts]

    @State private var text: String

    /// `initialText` exists so the surface can be RENDERED with an answer on screen. `@State` has
    /// no storage outside a rendered view, so a probe cannot type into this field, and a tester
    /// whose answer nobody has looked at is exactly the kind of thing that ships subtly wrong.
    init(registry: PersonRegistry, factsById: [String: PersonFilingFacts], initialText: String = "") {
        self.registry = registry
        self.factsById = factsById
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Try a filename — Aditi Abhishek - OCI Card.pdf", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").hoverInk()
                    }
                    .buttonStyle(.hoverAffordance(.inline))
                    .help("Clear")
                }
            }
            if !text.isEmpty {
                answer
            }
        }
    }

    @ViewBuilder
    private var answer: some View {
        let report = registry.explain(in: stem)
        if report.isEmpty {
            Label("Names nobody — Organize would file this without a person to go on.",
                  systemImage: "person.slash")
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                // Keyed on the match, not the person: one person can legitimately match twice
                // (a phrase and a token), and a duplicated `id` makes SwiftUI collapse the rows
                // unpredictably — in the list whose whole purpose is to show what matched.
                ForEach(Array(report.matches.enumerated()), id: \.offset) { _, match in
                    Label(line(for: match), systemImage: "person.fill.checkmark")
                        .scaledFont(.subheadline)
                        .foregroundStyle(SemanticColor.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The consequence, not just the identification — "who" is only interesting because
                // of what it decides.
                if let consequence {
                    Text(consequence)
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The counter-intuitive half, and the reason full names are worth entering.
                ForEach(report.absorbed, id: \.word) { absorbed in
                    Text(absorbedLine(absorbed))
                        .scaledFont(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// The extension is stripped, because that is what the veto matches on — testing the raw string
    /// would answer a question the engine never asks.
    private var stem: String { Self.stem(of: text) }

    /// `nonisolated` here and on the four rules below, for the reason `RailItemLabel.badgeText`
    /// states: a `View`'s static members inherit `@MainActor`, so a pure rule extracted for testing
    /// is reachable only from the main actor — and a test suite that is not itself `@MainActor`
    /// does not fail to compile, it **traps the test host at runtime**, which reports as
    /// infrastructure rather than as a failure. These read their inputs and return a String; there
    /// is nothing here for the main actor to protect.
    nonisolated static func stem(of filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }

    private func line(for match: PersonMatch) -> String {
        Self.line(for: match, registry: registry)
    }

    nonisolated static func line(for match: PersonMatch, registry: PersonRegistry) -> String {
        let who = displayName(match.personId, in: registry)
        return match.isPhrase
            ? "\(who) — matched the full name “\(match.form)”"
            : "\(who) — matched “\(match.form)”"
    }

    private var consequence: String? {
        Self.consequence(of: stem, registry: registry, factsById: factsById)
    }

    /// What identifying them actually does, in this tree, with real numbers.
    ///
    /// **Static so it can be asserted.** This file had 136 lines and no test of any kind: the
    /// surface is reachable only from `SettingsView` and an env-gated render probe, so reverting
    /// one line here reinstated the defect the comment below documents with nothing to catch it.
    /// The rule is small and the wrong answer it produced was a *contradiction of the engine*,
    /// which is the worst thing a diagnostic can do.
    nonisolated static func consequence(of stem: String, registry: PersonRegistry,
                            factsById: [String: PersonFilingFacts]) -> String? {
        // **Distinct people.** `matches` can hold two entries for ONE person — a phrase match plus
        // a token match, or two different strong tokens — and the dedupe in `explain` only removes
        // exact repeats of the same word. Counting rows made `Mom - Muktha Girish Passport.pdf`
        // report "2 people are named, so no folder is refused", while `detect` (a Set) returns one
        // person and the cross-person veto does fire. The diagnostic contradicted the engine it
        // exists to explain.
        let ids = Set(registry.explain(in: stem).matches.map(\.personId))
        guard ids.count == 1, let id = ids.first, let facts = factsById[id] else {
            // Counted, not assumed: three household members in one filename is an ordinary
            // scanned document, and "Two people are named" about three of them is simply wrong.
            return ids.count > 1
                ? "\(ids.count) people are named, so no folder is refused on anyone's behalf."
                : nil
        }
        guard facts.folderCount > 0 else {
            return "\(displayName(id, in: registry)) has no folders recorded yet, so this changes nothing."
        }
        let others = factsById.values.filter { $0.personId != id && $0.folderCount > 0 }.count
        let folders = facts.folderCount == 1 ? "their 1 folder" : "their \(facts.folderCount) folders"
        return others == 0
            ? "Prefers \(folders)."
            : "Prefers \(folders); refuses the other \(others == 1 ? "person's" : "\(others) people's")."
    }

    private func absorbedLine(_ absorbed: AbsorbedWord) -> String {
        Self.absorbedLine(absorbed, registry: registry)
    }

    nonisolated static func absorbedLine(_ absorbed: AbsorbedWord, registry: PersonRegistry) -> String {
        "“\(absorbed.word)” would have named \(displayName(absorbed.wouldHaveNamed, in: registry)) on its own — "
            + "“\(absorbed.absorbedInto)” claimed it first."
    }

    nonisolated static func displayName(_ id: String, in registry: PersonRegistry) -> String {
        registry.people.first { $0.id == id }?.displayName ?? id
    }
}
