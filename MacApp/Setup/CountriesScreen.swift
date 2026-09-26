import Design
import SwiftUI
import Sync

/// Screen 5: which of the short folder names are countries.
///
/// **The likely ones arrive ticked, and "likely" is measured.** A value pre-ticks only when it is a
/// real ISO region *and* it splits at least ``JurisdictionCandidates/confidentDistinctParents``
/// different parent folders — the bar the reference tree set. Everything else is proposed and left
/// for the user, because the mining is 83.2% right and every point of the gap is an invention:
/// `EMP` is an employer, `IT` a department, `PRD` a product stage.
struct CountriesScreen: View {
    @ObservedObject var model: SetupModel
    let hue: LiquidGlassHue

    var body: some View {
        VStack(alignment: .leading, spacing: SetupRhythm.blockSpacing) {
            SetupHeading(title: "Which of these are countries?", blurb: blurb)

            SetupWalkStatus(model: model, foundLabel: "Found in")

            // **What counts as a country first; what merely might, behind a disclosure.** Every
            // short folder name the walk saw arrived in one row, ticked and unticked together, so
            // the two the rule is confident about sat between `EMP`, `IT` and `PRD` with nothing
            // but a tick to separate them — and the unticked ones outnumber them. The answer is
            // the screen; the rest is a list to correct it from.
            VStack(alignment: .leading, spacing: SetupRhythm.groupSpacing) {
                Text("Counted as countries").scaledFont(.callout.weight(.semibold))
                if chosen.isEmpty {
                    Text(model.countryCandidates.isEmpty
                         ? "None. Add any by their code."
                         : "None yet — tick any below, or add one by its code.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    WrapLayout(spacing: 6) {
                        ForEach(chosen, id: \.self) { value in
                            chip(value, detail: detail(for: value), help: help(for: value))
                        }
                    }
                }
            }

            if !unchosen.isEmpty {
                SetupMoreOptions(
                    title: Self.suggestionsTitle(unchosen.count),
                    subtitle: "tick any that are countries",
                    startsOpen: chosen.isEmpty
                ) {
                    WrapLayout(spacing: 6) {
                        ForEach(unchosen, id: \.self) { value in
                            chip(value, detail: detail(for: value), help: help(for: value))
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("Add a country…", text: $model.newCountryField)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit { model.commitTypedCountry() }
                Button("Add") { model.commitTypedCountry() }
                    .controlSize(.small)
                    .disabled(model.newCountryField.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Spacer(minLength: 0)

            // **At the foot of the column, not under the chips.** The card is one fixed height for
            // all ten screens and this is one of the four that does not fill it, so a note tucked
            // under the controls left the column's bottom third empty while the Why panel beside it
            // closed on its own footnote — two columns of one card disagreeing about where the
            // floor is. Workspaces has always closed this way and is the better-composed screen for
            // it.
            Text("Ticked means a real country code that appears under "
                 + "\(SetupFlow.spelled(JurisdictionCandidates.confidentDistinctParents).lowercased()) "
                 + "or more different parent folders. Unticked names are read as ordinary folders. "
                 + "Add any the list missed by its code, like SG.")
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Every value on this screen, ticked or not: the walk's candidates plus anything typed.
    private var allValues: [String] {
        model.countryCandidates.map(\.value) + model.addedCountries
    }

    /// The ones that count as countries — the answer this screen exists to show.
    private var chosen: [String] {
        allValues.filter { model.confirmedCountries.contains($0) }
    }

    /// The ones offered and not taken.
    private var unchosen: [String] {
        allValues.filter { !model.confirmedCountries.contains($0) }
    }

    /// A value's count of folders, or "added" for one the user typed.
    private func detail(for value: String) -> String {
        guard let candidate = model.countryCandidates.first(where: { $0.value == value }) else {
            return "· added"
        }
        return Self.blastRadius(candidate)
    }

    private func help(for value: String) -> String {
        guard let candidate = model.countryCandidates.first(where: { $0.value == value }) else {
            return "Added by hand"
        }
        return Self.evidence(candidate)
    }

    static func suggestionsTitle(_ count: Int) -> String {
        "\(count) other short name\(count == 1 ? "" : "s")"
    }

    private var blurb: String {
        model.countryCandidates.isEmpty && model.walkState.isDone
            ? "No short folder names looked like countries. Add any by their code."
            : "SyncCloud ticked the ones it is confident about. Correct it below."
    }

    private func chip(_ value: String, detail: String, help: String) -> some View {
        let ticked = model.confirmedCountries.contains(value)
        return Button {
            model.toggleCountry(value)
        } label: {
            SetupChip(mark: .tick(ticked), title: value, detail: detail, isFilled: ticked)
        }
        .buttonStyle(.hoverAffordance(.segment))
        .help(help)
        .accessibilityLabel("\(value), \(help), \(ticked ? "a country" : "not a country")")
    }

    /// How many folders taking this value would be affected — the number that makes a tick a
    /// decision rather than a guess.
    static func blastRadius(_ candidate: JurisdictionCandidate) -> String {
        "· \(candidate.folderCount) folder\(candidate.folderCount == 1 ? "" : "s")"
    }

    static func evidence(_ candidate: JurisdictionCandidate) -> String {
        let parents = candidate.parents.prefix(3).joined(separator: ", ")
        let count = "\(candidate.folderCount) folder\(candidate.folderCount == 1 ? "" : "s")"
        return parents.isEmpty ? count : "\(count), under \(parents)"
    }
}

/// The Why panel beside Countries.
struct CountriesWhy: View {
    let hue: LiquidGlassHue
    let folderName: String

    var body: some View {
        SetupWhyPanel(footnoteLead: "If you change nothing:",
                      footnote: "the ticked ones count as countries.",
                      hue: hue) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(folderName).scaledFont(.caption.weight(.semibold))
                    Group {
                        Text("Finance").padding(.leading, 8)
                        Text("US · IN").padding(.leading, 18).foregroundStyle(.tint)
                        Text("School").padding(.leading, 8)
                    }
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                }
                .accessibilityHidden(true)
                Text("US is a country, not a topic. Knowing that lets Organize keep \"country, then "
                     + "year\" as the shape of your folders instead of treating US as a subject.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
