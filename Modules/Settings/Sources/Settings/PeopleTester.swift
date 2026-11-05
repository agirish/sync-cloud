import Design
import Sync
import SwiftUI

/// Type a filename, see who Organize would say it belongs to, and what that decides.
///
/// The rest of the section reports state; this shows the rule running, which is what the user is
/// asked to trust. "Daughter Father" naming one person, not two, makes sense only once seen.
/// Answers come from ``PersonRegistry/explain(in:)``, the call `detect` is built on, so this can't
/// agree with a rule the engine doesn't have.
struct PeopleTester: View {
    let registry: PersonRegistry
    let factsById: [String: PersonFilingFacts]

    @State private var text: String

    /// `initialText` lets a render probe show an answer on screen: `@State` has no storage outside
    /// a rendered view, so a probe can't type into the field.
    init(registry: PersonRegistry, factsById: [String: PersonFilingFacts], initialText: String = "") {
        self.registry = registry
        self.factsById = factsById
        _text = State(initialValue: initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                // The section is titled "Try a filename", so the placeholder shows only the
                // example rather than repeating the title.
                TextField("Daughter Father - OCI Card.pdf", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .help("Type a filename to see who Organize would say it belongs to. Nothing is filed.")
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").hoverInk()
                    }
                    .buttonStyle(.hoverAffordance(.inline))
                    .help("Clear")
                    .accessibilityLabel("Clear the text")
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
                // Keyed on the match, not the person: one person can match twice (a phrase and a
                // token), and a duplicated `id` makes SwiftUI collapse rows unpredictably.
                ForEach(Array(report.matches.enumerated()), id: \.offset) { _, match in
                    Label(line(for: match), systemImage: "person.fill.checkmark")
                        .scaledFont(.subheadline)
                        .foregroundStyle(SemanticColor.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The consequence, not just the identification: "who" matters for what it decides.
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

    /// The name without its extension, because that is what the veto matches on.
    private var stem: String { Self.stem(of: text) }

    /// `nonisolated` here and on the rules below, as `RailItemLabel.badgeText` explains: a `View`'s
    /// static members inherit `@MainActor`, and calling one from a suite that isn't `@MainActor`
    /// compiles but **traps the test host at runtime**. These are pure string rules.
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

    /// What identifying them actually does, in this tree, with real numbers. Static so
    /// `PeopleTesterTests` can assert it: the surface is otherwise reachable only from
    /// `SettingsView` and an env-gated render probe.
    nonisolated static func consequence(of stem: String, registry: PersonRegistry,
                                        factsById: [String: PersonFilingFacts]) -> String? {
        // Count distinct people, as `detect` (a Set) does. `matches` can hold two entries for one
        // person (a phrase and a token, or two strong tokens); counting rows would say "2 people
        // are named" where the engine sees one and the cross-person veto fires.
        let ids = Set(registry.explain(in: stem).matches.map(\.personId))
        guard ids.count == 1, let id = ids.first, let facts = factsById[id] else {
            // Counted, not assumed: three household members in one filename is ordinary.
            return ids.count > 1
                ? "\(ids.count) people are named, so no folder is refused on anyone’s behalf."
                : nil
        }
        guard facts.folderCount > 0 else {
            return "\(displayName(id, in: registry)) has no folders recorded yet, so this changes nothing."
        }
        let others = factsById.values.filter { $0.personId != id && $0.folderCount > 0 }.count
        let folders = facts.folderCount == 1 ? "their 1 folder" : "their \(facts.folderCount) folders"
        return others == 0
            ? "Prefers \(folders)."
            : "Prefers \(folders); refuses the other \(others == 1 ? "person’s" : "\(others) people’s")."
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
