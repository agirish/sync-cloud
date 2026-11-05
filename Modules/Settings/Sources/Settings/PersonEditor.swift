import Design
import Sync
import SwiftUI

/// Add or edit one person on the list.
///
/// The editor's real job is teaching. A user can't guess why full names matter: "Daughter Father"
/// resolves to one person only because the phrase is listed, and without it a shared surname makes
/// two people out of one document. So the sheet shows, live, what the draft would match and which
/// of its words are that person's alone.
///
/// One sheet for adding and editing, told apart by `isNew`, as in `AutomationRuleEditor`.
struct PersonEditor: View {
    let isNew: Bool
    let roster: [Person]
    let onSave: (Person) -> Void
    let onCancel: () -> Void

    @State private var draft: Person
    /// The two add-fields. Internal so a test can stage a name typed but not committed with ⏎,
    /// which is otherwise unreachable without driving a window.
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
                .shortcutKeycap("↩")
                .buttonStyle(.borderedProminent)
                .accentedProminent()
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
                    .help("Their relationship to you — a label for you only; it changes nothing about filing.")
            }
            Text("The first name is what your folders are called — `School/\(draft.displayName.isEmpty ? "Daughter" : draft.displayName)`. The relationship is a label for you; it changes nothing about filing.")
                .scaledFont(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fullNamesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow("Full names on documents")
            Text("Every form a document might print. **This is the field that does the work**: a full name is matched before any single word, so “Daughter Father” names Daughter alone even though “Father” is someone else here.")
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
            Text("What you call them in a filename when you do not use their name — “Mom”, “Dad”. These resolve to the same person, so `Mom - passport.pdf` belongs in Granny’s folder.")
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

    /// What this draft would actually match, recomputed as it is typed. Built against the rest of
    /// the roster, because whether "elder" is distinctive is a fact about the whole list: judged
    /// alone, every word would look like theirs.
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
                    // Amber only when the sharing costs something: every family member shares a
                    // word with somebody, and a caution on everyone stops being read.
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

    /// The saved values as removable chips, flow-wrapped: they are short and rarely more than four,
    /// and a column of rows would make the sheet scroll.
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

    /// A person needs a name and nothing else. The rest is evidence, and a record without any is
    /// still how a folder gets recognised as theirs.
    nonisolated static func canSave(displayName: String) -> Bool {
        !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The draft as it would be stored, with a pending entry in either add-field folded in.
    var assembled: Person {
        Self.folding(draft, pendingFullName: fullNameDraft, pendingAlias: aliasDraft)
    }

    /// Fold a half-typed add-field into the record: a name typed but not committed with ⏎ is still
    /// an edit, and **Save must not discard it**, the likeliest way to lose work in this sheet.
    ///
    /// Static rather than inside `assembled` because `@State` has no storage outside a rendered
    /// view: a test that set `fullNameDraft` and read `assembled` would see the initial value and
    /// pass for the wrong reason.
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

    /// The shared-word line, from ``PersonFilingFacts/sharedSummary`` so it and the row's tooltip
    /// say the same thing, with the consequence appended when there is one.
    private func sharedLine(_ facts: PersonFilingFacts) -> String {
        let head = "Shared with others on this list: " + facts.sharedSummary
        return facts.isAttributable
            ? head
            : head + ". Add a full name, or documents naming only these words cannot be attributed."
    }
}

/// A minimal wrapping stack for the chips.
///
/// Not Design's `TokenChipsRow`, a single non-wrapping line built for rule tokens: four name forms
/// overflow it, and widening it would change every rule card.
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
