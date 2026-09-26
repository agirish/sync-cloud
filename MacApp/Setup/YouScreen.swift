import Design
import Settings
import SwiftUI
import Sync

/// Screen 3: your name, and the forms of it a document might print.
///
/// **The forms are the answer, not the name.** Organize reads the names printed on a page to tell
/// whose a document is, and the matcher is positional — `Girish Abhishek` and `Abhishek Girish` are
/// two different strings and both appear on real statements. The surname exists to build those
/// forms and is never stored on its own.
struct YouScreen: View {
    @ObservedObject var model: SetupModel
    let hue: LiquidGlassHue
    @FocusState.Binding var firstFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SetupRhythm.blockSpacing) {
            SetupHeading(title: "Is this you?", blurb: blurb)

            HStack(alignment: .top, spacing: 12) {
                field("First name", text: $model.firstName, focused: true)
                field("Surname · optional", text: $model.surname, focused: false)
            }

            VStack(alignment: .leading, spacing: SetupRhythm.groupSpacing) {
                Text("How documents print your name")
                    .scaledFont(.callout.weight(.semibold))
                if model.firstName.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text("Type a name above and the forms appear here.")
                        .scaledFont(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    WrapLayout(spacing: 6) {
                        ForEach(model.offeredNameForms, id: \.form) { form in
                            formChip(form.form, ticked: form.ticked)
                        }
                    }
                    HStack(spacing: 6) {
                        TextField("Another form…", text: $model.newFormField)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 190)
                            .onSubmit { model.commitTypedForm() }
                        Button("Add") { model.commitTypedForm() }
                            .controlSize(.small)
                            .disabled(model.newFormField.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            SetupMoreOptions(subtitle: "Nicknames, like Dad") {
                Text("A nickname is another form of your name: add it above and Organize matches "
                     + "it like any other.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            // At the foot of the column — see the note on Countries' closing line.
            Text("Order matters, so surname-first is its own form. Tick initials only if they "
                 + "can't mean anyone else.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the screen says it knows, and where from — never an assertion.
    ///
    /// The Mac account name is a real name in the overwhelming case and `admin` in the rest, so it
    /// is offered as evidence rather than as an answer. A folder in the learned tree that matches
    /// is the corroboration, and it is only mentioned when there is one.
    private var blurb: String {
        let account = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        switch (account.isEmpty, model.matchedFolder) {
        case (false, .some(let folder)):
            return "Your Mac account says \(account), and \(model.walkRootName) has a folder named "
                + "\(folder). Correct either field if it's wrong."
        case (false, .none):
            return "Your Mac account says \(account). Correct either field if it's wrong."
        default:
            return "Type the name your documents print."
        }
    }

    private func field(_ label: String, text: Binding<String>, focused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).scaledFont(.caption).foregroundStyle(.secondary)
            Group {
                if focused {
                    TextField("", text: text)
                        .focused($firstFieldFocused)
                } else {
                    TextField("", text: text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .frame(width: 190)
            .accessibilityLabel(label)
        }
    }

    private func formChip(_ form: String, ticked: Bool) -> some View {
        Button {
            model.toggleForm(form)
        } label: {
            SetupChip(mark: .tick(ticked), title: form, isFilled: ticked)
        }
        .buttonStyle(.hoverAffordance(.segment))
        .accessibilityLabel("\(form), \(ticked ? "used" : "not used")")
    }
}

/// The Why panel beside You.
struct YouWhy: View {
    let hue: LiquidGlassHue
    let firstName: String

    var body: some View {
        SetupWhyPanel(footnoteLead: "If you skip:",
                      footnote: "Organize can't tell which documents are yours.",
                      hue: hue) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .scaledFont(.system(size: 20))
                        .foregroundStyle(.secondary)
                    Text(firstName.isEmpty ? "yours" : firstName)
                        .scaledFont(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                }
                .accessibilityHidden(true)
                Text("Organize reads the names printed on a document to tell whose it is. It needs "
                     + "yours, in every form a page might print.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The surname is only used to build these forms. The forms are saved; the "
                     + "surname itself is not.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
