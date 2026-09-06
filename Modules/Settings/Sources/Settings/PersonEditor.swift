import Design
import Sync
import SwiftUI

/// Add or edit one person on the list.
///
/// **The editor's real job is teaching, not data entry.** Two fields would have been enough to
/// store a person; what a user cannot guess is *why* the full names matter — that "Aditi Abhishek"
/// resolves to one person only because the phrase is listed, and that without it a shared surname
/// makes two people out of one document. So the sheet shows, live, what the draft would match and
/// which of its words are that person's alone. Editing a name and watching "shared with 3 others"
/// disappear is the explanation; a paragraph of help text is not.
///
/// One sheet for both jobs, distinguished by `isNew`, the same way `AutomationRuleEditor` handles
/// new-versus-existing rules.
struct PersonEditor: View {
    let isNew: Bool
    let roster: [Person]
    let onSave: (Person) -> Void
    let onCancel: () -> Void

    @State private var draft: Person
    /// The two add-fields. Internal rather than private so a test can stage the state that loses an
    /// edit — a name typed and not yet committed with ⏎ — which is otherwise unreachable without
    /// driving a window.
    @State var fullNameDraft = ""
    @State var aliasDraft = ""
    @FocusState private var nameFieldFocused: Bool

    init(person: Person, isNew: Bool, roster: [Person],
         onSave: @escaping (Person) -> Void, onCancel: @escaping () -> Void) {
        self.isNew = isNew
        self.roster = roster
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: person)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identitySection
                    fullNamesSection
                    aliasesSection
                    matchPreview
                }
                .padding(18)
            }
            Divider()
            footer
        }
        .frame(width: 480, height: 560)
        .onAppear { nameFieldFocused = isNew }
    }

    // MARK: - Header and footer

    private var header: some View {
        HStack {
            Text(isNew ? "Add Person" : "Edit \(draft.displayName)").scaledFont(.headline)
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", action: onCancel)
                .keyboardShortcut(.cancelAction)
                .shortcutKeycap("esc")
            Button(isNew ? "Add" : "Save") { onSave(assembled) }
                .keyboardShortcut(.defaultAction)
                .shortcutKeycap("⏎")
                .buttonStyle(.borderedProminent)
                .chromeHover()
                .disabled(!Self.canSave(displayName: draft.displayName))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Sections

    private var identitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow("Who")
            HStack(spacing: 8) {
                TextField("First name", text: $draft.displayName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .focused($nameFieldFocused)
                    .frame(maxWidth: 160)
                TextField("wife, son, mother…", text: Binding(
                    get: { draft.relationship ?? "" },
                    set: { draft.relationship = $0.isEmpty ? nil : $0 }))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }
            Text("The first name is what your folders are called — `School/\(draft.displayName.isEmpty ? "Aditi" : draft.displayName)`. The relationship is a label for you; it changes nothing about filing.")
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fullNamesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow("Full names on documents")
            Text("Every form a document might print. **This is the field that does the work**: a full name is matched before any single word, so “Aditi Abhishek” names Aditi alone even though “Abhishek” is someone else here.")
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            chips(draft.fullNames) { name in
                draft.fullNames.removeAll { $0 == name }
            }
            addRow(placeholder: "Add a name a document prints…", text: $fullNameDraft) {
                append($fullNameDraft.wrappedValue, to: \.fullNames)
            }
        }
    }

    private var aliasesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow("Also called")
            Text("What you call them in a filename when you do not use their name — “Mom”, “Dad”. These resolve to the same person, so `Mom - passport.pdf` belongs in Muktha's folder.")
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            chips(draft.aliases) { alias in
                draft.aliases.removeAll { $0 == alias }
            }
            addRow(placeholder: "Add what you call them…", text: $aliasDraft) {
                append($aliasDraft.wrappedValue, to: \.aliases)
            }
        }
    }

    /// What this draft would actually match, recomputed as it is typed.
    ///
    /// Built against the **rest of the roster**, so the shared-word warning is true: whether
    /// "girish" is distinctive is a fact about the whole list, not about this person, and a preview
    /// that judged them in isolation would say every word was theirs alone.
    private var matchPreview: some View {
        let facts = previewFacts
        return VStack(alignment: .leading, spacing: 8) {
            eyebrow("What Organize will match")
            if facts.matchedForms.isEmpty {
                Text("Nothing yet — give them a first name.")
                    .scaledFont(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(facts.matchedForms.joined(separator: " · "))
                    .scaledFont(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                if !facts.uniqueWords.isEmpty {
                    Label("Theirs alone: " + facts.uniqueWords.joined(separator: ", "),
                          systemImage: "checkmark.circle")
                        .scaledFont(.subheadline)
                        .foregroundStyle(SemanticColor.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !facts.sharedWords.isEmpty {
                    // Amber only when the sharing actually costs something. Every member of a
                    // family shares a word with somebody; saying so in the alarm colour on every
                    // person is how a caution stops being read.
                    Label(sharedLine(facts),
                          systemImage: facts.isAttributable ? "info.circle" : "exclamationmark.triangle")
                        .scaledFont(.subheadline)
                        .foregroundStyle(facts.isAttributable ? AnyShapeStyle(.secondary)
                                                              : AnyShapeStyle(SemanticColor.caution))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - Pieces

    private func eyebrow(_ text: String) -> some View {
        Text(text)
            .textCase(.uppercase)
            .scaledFont(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .kerning(0.4)
    }

    /// The saved values as removable chips. Flow-wrapped rather than a column: these are short and
    /// there are rarely more than four, and a stack of one-line rows made the sheet scroll for
    /// nothing.
    private func chips(_ values: [String], remove: @escaping (String) -> Void) -> some View {
        FlowLayout(spacing: 6) {
            ForEach(values, id: \.self) { value in
                HStack(spacing: 4) {
                    Text(value).scaledFont(.caption)
                    Button { remove(value) } label: {
                        Image(systemName: "xmark.circle.fill").hoverInk()
                    }
                    .buttonStyle(.hoverAffordance(.inline))
                    .help("Remove “\(value)”")
                    .accessibilityLabel("Remove \(value)")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.secondary.opacity(0.12)))
            }
        }
    }

    private func addRow(placeholder: String, text: Binding<String>,
                        add: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit(add)
            Button("Add", action: add)
                .controlSize(.small)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - Logic, kept `nonisolated static` so tests can reach it without a window

    /// A person needs a name and nothing else. Everything below it is evidence, and a record with
    /// no evidence is still worth keeping — it is how a folder gets recognised as theirs at all.
    nonisolated static func canSave(displayName: String) -> Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The draft as it would be stored, with a pending entry in either add-field folded in.
    var assembled: Person {
        Self.folding(draft, pendingFullName: fullNameDraft, pendingAlias: aliasDraft)
    }

    /// Fold a half-typed add-field into the record.
    ///
    /// **A `nonisolated static` function rather than logic inside `assembled`, because the state it
    /// reads is unreachable from a test otherwise**: `@State` has no storage outside a rendered
    /// view, so assigning `fullNameDraft` on a constructed editor and reading `assembled` back
    /// returns the initial value and the test passes for the wrong reason. The rule under test is
    /// here; the view only supplies its inputs.
    ///
    /// The rule itself: a name typed but not committed with ⏎ is still an edit the user made, and
    /// pressing Save must not discard it — the single most likely way to lose work in this sheet.
    nonisolated static func folding(_ person: Person, pendingFullName: String,
                                    pendingAlias: String) -> Person {
        var out = person
        out.displayName = person.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = pendingFullName.trimmingCharacters(in: .whitespaces)
        if !full.isEmpty, !out.fullNames.contains(where: { $0.lowercased() == full.lowercased() }) {
            out.fullNames.append(full)
        }
        let alias = pendingAlias.trimmingCharacters(in: .whitespaces)
        if !alias.isEmpty, !out.aliases.contains(where: { $0.lowercased() == alias.lowercased() }) {
            out.aliases.append(alias)
        }
        return out
    }

    private func append(_ raw: String, to keyPath: WritableKeyPath<Person, [String]>) {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        if !draft[keyPath: keyPath].contains(where: { $0.lowercased() == value.lowercased() }) {
            draft[keyPath: keyPath].append(value)
        }
        if keyPath == \Person.fullNames { fullNameDraft = "" } else { aliasDraft = "" }
    }

    /// Facts for the draft, judged against everyone else on the list.
    private var previewFacts: PersonFilingFacts {
        let me = assembled
        guard !me.displayName.isEmpty else { return .none }
        // A new person has no id yet; give the preview a private one that cannot collide.
        let id = me.id.isEmpty ? "__draft__" : me.id
        var previewPerson = me
        if me.id.isEmpty {
            previewPerson = Person(id: id, displayName: me.displayName,
                                   relationship: me.relationship,
                                   fullNames: me.fullNames, aliases: me.aliases)
        }
        let others = roster.filter { $0.id != previewPerson.id }
        let registry = PersonRegistry(people: others + [previewPerson])
        return PersonFilingFacts.make(for: previewPerson, registry: registry,
                                      profile: nil, memory: nil)
    }

    /// The shared-word line. Phrased from ``PersonFilingFacts/sharedSummary`` so the row's tooltip
    /// and this cannot describe the same fact differently, with the consequence appended only when
    /// there is one.
    private func sharedLine(_ facts: PersonFilingFacts) -> String {
        let head = "Shared with others on this list: " + facts.sharedSummary
        return facts.isAttributable
            ? head
            : head + ". Add a full name, or documents naming only these words cannot be attributed."
    }
}

/// A minimal wrapping stack for the chips.
///
/// Written here rather than reached for from Design because the one existing chip row
/// (`TokenChipsRow`) is a single non-wrapping line built for rule tokens — a person with four name
/// forms overflows it, and widening that type would change every rule card that uses it.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, in: width)
        guard let last = rows.last else { return .zero }
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: last.y + last.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews,
                       cache: inout ()) {
        let rows = arrange(subviews: subviews, in: bounds.width)
        for row in rows {
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y),
                    proposal: ProposedViewSize(item.size))
            }
        }
    }

    private struct Row {
        var y: CGFloat = 0
        var height: CGFloat = 0
        var width: CGFloat = 0
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
    }

    private func arrange(subviews: Subviews, in width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        var x: CGFloat = 0
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                row.width = x - spacing
                rows.append(row)
                row = Row(y: row.y + row.height + spacing)
                x = 0
            }
            row.items.append((i, x, size))
            row.height = max(row.height, size.height)
            x += size.width + spacing
        }
        if !row.items.isEmpty {
            row.width = x - spacing
            rows.append(row)
        }
        return rows
    }
}
