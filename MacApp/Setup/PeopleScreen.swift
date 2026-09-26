import Design
import Settings
import SwiftUI
import Sync

/// Screen 4: who else the folders name.
///
/// **Nothing is ticked when you arrive.** The proposer over-proposes on purpose — `Taxes` sits
/// under `Family` too, and only the user knows which of these names are people — so every chip
/// carries the folder that vouches for it and adding one is a click.
struct PeopleScreen: View {
    @ObservedObject var model: SetupModel
    let hue: LiquidGlassHue

    var body: some View {
        VStack(alignment: .leading, spacing: SetupRhythm.blockSpacing) {
            SetupHeading(title: "Who else is in your folders?", blurb: blurb)

            SetupWalkStatus(model: model, foundLabel: "Found in")

            // **The list first, the suggestions behind it.** The proposer over-proposes on purpose
            // — `Taxes` sits under `Family` too — so the candidates are the longest row on the
            // screen and the least settled thing on it, and putting them at the top made the
            // screen's answer, the roster, look like a footnote to a pile of guesses. The
            // disclosure opens itself while the list is empty, which is the run where the
            // candidates *are* the screen.
            VStack(alignment: .leading, spacing: SetupRhythm.groupSpacing) {
                Text("On the list").scaledFont(.callout.weight(.semibold))
                if model.rosterNames.isEmpty {
                    Text(model.visiblePeopleCandidates.isEmpty
                         ? "Nobody yet. Add anyone whose documents you keep."
                         : "Nobody yet — tick a name below, or add one.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                }
                FlowChips(items: model.rosterNames,
                          subtitle: { model.relationship(of: $0).map { "· \($0)" } },
                          onRemove: { model.removePerson(named: $0) })
                HStack(spacing: 6) {
                    TextField("Add someone…", text: $model.newPersonField)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 190)
                        .onSubmit { model.commitTypedPerson() }
                        .disabled(model.rosterIsReadOnly)
                    Button("Add") { model.commitTypedPerson() }
                        .controlSize(.small)
                        .disabled(model.rosterIsReadOnly
                                  || model.newPersonField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if !model.visiblePeopleCandidates.isEmpty {
                SetupMoreOptions(
                    title: Self.suggestionsTitle(model.visiblePeopleCandidates.count),
                    subtitle: "tick any that are people",
                    startsOpen: model.rosterNames.isEmpty
                ) {
                    WrapLayout(spacing: 6) {
                        ForEach(model.visiblePeopleCandidates) { candidate in
                            candidateChip(candidate)
                        }
                    }
                }
            }

            // Both of the store's refusals, in its own terms — the sheet must not offer edits that
            // would silently do nothing.
            if model.rosterIsReadOnly {
                SetupNote(text: SetupFlow.peopleSummary(otherCount: model.rosterNames.count,
                                                        rosterIsReadOnly: true),
                          systemImage: "exclamationmark.triangle")
            }

            Spacer(minLength: 0)
        }
    }

    /// The disclosure's name, which is a count and therefore has to be built rather than written.
    static func suggestionsTitle(_ count: Int) -> String {
        "\(count) name\(count == 1 ? "" : "s") SyncCloud found"
    }

    private var blurb: String {
        switch model.walkState {
        case .done where !model.visiblePeopleCandidates.isEmpty:
            return "Anyone whose documents you keep. SyncCloud found some names to offer."
        case .done:
            return "No folder names looked like people. Add anyone by hand."
        case .skipped:
            return "Add anyone whose documents you keep."
        case .failed:
            return "Add anyone whose documents you keep."
        default:
            return "Anyone whose documents you keep. SyncCloud found some names to offer."
        }
    }

    private func candidateChip(_ candidate: PersonCandidate) -> some View {
        Button {
            model.addProposedPerson(candidate)
        } label: {
            SetupChip(mark: .add, title: candidate.name, detail: parentDetail(candidate))
        }
        .buttonStyle(.hoverAffordance(.segment))
        .disabled(model.rosterIsReadOnly)
        .help(Self.evidence(candidate))
        .accessibilityLabel("Add \(candidate.name), \(Self.evidence(candidate))")
    }

    /// The folder that vouches for a candidate, or nothing when the proposer had no parent to
    /// name — an empty detail draws nothing rather than an empty gap.
    private func parentDetail(_ candidate: PersonCandidate) -> String? {
        guard let parent = candidate.parents.first, !parent.isEmpty else { return nil }
        return "in \(parent)"
    }

    static func evidence(_ candidate: PersonCandidate) -> String {
        let parents = candidate.parents.filter { !$0.isEmpty }.prefix(3).joined(separator: ", ")
        let count = "\(candidate.folderCount) folder\(candidate.folderCount == 1 ? "" : "s")"
        return parents.isEmpty ? count : "\(count) under \(parents)"
    }
}

/// The line that stands where found items go while the walk is running, failed or skipped.
///
/// **Every screen after Learn has three states and none of them blocks.** Continue never waits, so
/// You, People and Countries can all be reached before the walk is done — and any of them can be
/// reached after it has failed.
struct SetupWalkStatus: View {
    @ObservedObject var model: SetupModel
    var foundLabel: String

    var body: some View {
        switch model.walkState {
        case .running:
            HStack(spacing: 7) {
                InlineSpinner()
                Text("Reading names…").scaledFont(.caption).foregroundStyle(.secondary)
            }
        case .done:
            HStack(spacing: 6) {
                Image(systemName: "folder").scaledFont(.caption2).foregroundStyle(.tertiary)
                Text("\(foundLabel) \(model.walkRootName)")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                // Changing the folder here re-reads it; see `chooseWalkRoot(thenLearn:)`.
                Button("Change…") { model.chooseWalkRoot(thenLearn: true) }
                    .controlSize(.mini)
                    .buttonStyle(.link)
            }
        case .idle, .skipped:
            // **`.idle` is not `.running`.** Nothing is reading, so nothing claims to be: the
            // screen is simply the roster and the field, which is what it is on a skipped walk
            // too. Drawing a spinner here made a folder changed and not re-read look like a read
            // that never finished.
            EmptyView()
        case .failed(let why):
            VStack(alignment: .leading, spacing: 5) {
                Label("Couldn't read that folder", systemImage: "exclamationmark.triangle")
                    .scaledFont(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(why)
                    .scaledFont(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try another folder…") { model.screen = .learn }
                    .controlSize(.small)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Color.secondary.opacity(0.07)))
        }
    }
}

/// The Why panel beside People.
struct PeopleWhy: View {
    let hue: LiquidGlassHue

    var body: some View {
        SetupWhyPanel(footnoteLead: "If you skip:",
                      footnote: "Organize files only for you. Add people any time.",
                      hue: hue) {
            VStack(alignment: .leading, spacing: 8) {
                Text("A letter to Maya belongs in Maya's folder, not yours. Organize can only do "
                     + "that if it knows who Maya is.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nothing is ticked when you arrive: a folder under Family may not be a person, "
                     + "and only you know which names are. Ticking one adds it to the list above.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
