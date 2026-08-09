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
                ForEach(report.matches, id: \.personId) { match in
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
    private var stem: String { (text as NSString).deletingPathExtension }

    private func line(for match: PersonMatch) -> String {
        let who = displayName(match.personId)
        return match.isPhrase
            ? "\(who) — matched the full name “\(match.form)”"
            : "\(who) — matched “\(match.form)”"
    }

    /// What identifying them actually does, in this tree, with real numbers.
    private var consequence: String? {
        let ids = registry.explain(in: stem).matches.map(\.personId)
        guard ids.count == 1, let id = ids.first, let facts = factsById[id] else {
            return ids.count > 1
                ? "Two people are named, so no folder is refused on either's behalf."
                : nil
        }
        guard facts.folderCount > 0 else {
            return "\(displayName(id)) has no folders recorded yet, so this changes nothing."
        }
        let others = factsById.values.filter { $0.personId != id && $0.folderCount > 0 }.count
        let folders = facts.folderCount == 1 ? "their 1 folder" : "their \(facts.folderCount) folders"
        return others == 0
            ? "Prefers \(folders)."
            : "Prefers \(folders); refuses the other \(others) people's."
    }

    private func absorbedLine(_ absorbed: AbsorbedWord) -> String {
        "“\(absorbed.word)” would have named \(displayName(absorbed.wouldHaveNamed)) on its own — "
            + "“\(absorbed.absorbedInto)” claimed it first."
    }

    private func displayName(_ id: String) -> String {
        registry.people.first { $0.id == id }?.displayName ?? id
    }
}
