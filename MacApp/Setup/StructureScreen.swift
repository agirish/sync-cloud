import Design
import SwiftUI
import Sync

/// The screen the whole redesign exists for: what SyncCloud read, shown back before anything is
/// written.
///
/// **A walk that reports only counts cannot be checked.** The form this replaces printed
/// "2,306 folders" and moved on; here the reading is on screen while going Back still costs
/// nothing, so a wrong name, a wrong country or the wrong folder is caught before the profile
/// exists rather than after Organize has been acting on it for a week.
struct StructureScreen: View {
    @ObservedObject var model: SetupModel
    let hue: LiquidGlassHue

    /// Which of the two views of the same tree is showing.
    enum Lens: String, CaseIterable, Identifiable {
        case folders, loose
        var id: String { rawValue }
        var title: String {
            switch self {
            case .folders: return "Your folders"
            case .loose: return "Where loose files would go"
            }
        }
    }

    @State private var lens: Lens = .folders
    /// The box is sized in points and everything in it scales, so the box scales too — a fixed
    /// height at 135% text shows four rows of a tree the user is being asked to check.
    ///
    /// It follows the *card*, not the type: on a window too small to give the card its full growth
    /// the box would otherwise claim room the card never got, and push the switch below it out of
    /// sight. `theTreeBoxNeverOutgrowsTheCard` is the measurement.
    @Environment(\.setupCardScale) private var cardScale

    /// None while a reading runs — see ``SetupModel/structureShownProfile``.
    private var profile: FolderProfile? { model.structureShownProfile }

    var body: some View {
        VStack(alignment: .leading, spacing: SetupRhythm.blockSpacing) {
            SetupHeading(title: "Here is how you file", blurb: blurb)

            statsRow

            if model.structureIsReadOnly {
                SetupNote(text: "This is the folder profile this Mac already has. Learn a folder "
                          + "again to replace it — nothing here is written.",
                          systemImage: "info.circle")
            } else if !model.structureShowsWalkStatus {
                // No lens while the reading runs or after it failed: there is no tree to view
                // either way.
                Picker("", selection: $lens) {
                    ForEach(Lens.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(hue)
                .help("Switch between your folders and where loose files would go")
                .frame(maxWidth: 320, alignment: .leading)
            }

            // **The tree, the line that explains its grey words and the legend behind them are
            // one block, at the tighter spacing.** They are three parts of one thing, and spacing
            // them as three separate blocks both read wrong and cost 18pt — on the only screen of
            // the ten that has none to spare.
            VStack(alignment: .leading, spacing: SetupRhythm.groupSpacing) {
                if let profile {
                    SetupTreeView(profile: profile,
                                  readings: model.readings(for: profile),
                                  rootName: model.walkRootName,
                                  rootSubtitle: lens == .folders
                                      ? "the folder SyncCloud learned"
                                      : model.looseRoutes.count == 1 ? "1 file sitting loose here"
                                          : "\(model.looseRoutes.count.formatted()) files sitting loose here",
                                  routes: lens == .loose && !model.structureIsReadOnly
                                      ? model.looseRoutes : [],
                                  hue: hue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: Self.treeHeight * cardScale)
                } else if model.structureShowsWalkStatus {
                    // **The reading is still running, or failed, so this says so** — the line
                    // People and Countries draw for the same states, in the box the tree will fill.
                    SetupWalkStatus(model: model, foundLabel: "Read from")
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(height: Self.treeHeight * cardScale, alignment: .top)
                } else {
                    SetupNote(text: "Nothing has been learned yet.", systemImage: "folder")
                        .frame(height: Self.treeHeight * cardScale, alignment: .top)
                }

                // **A failed Save is said here, in place of the line about grey words**, because
                // this is the screen the press stays on — and next to the button that will try
                // again. Said as a write that failed: the folder was read, and the tree is still
                // above.
                if let failure = model.saveFailure {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(Self.saveFailedHeading, systemImage: "exclamationmark.triangle")
                            .scaledFont(.caption.weight(.medium))
                        Text(failure + " " + Self.saveFailedNextStep)
                            .scaledFont(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                } else if !model.structureShowsWalkStatus {
                    // The grey words and their legend explain a tree, and there is none yet.
                    Text(lens == .folders
                         ? "Gray words are how each folder’s name was read. Nothing inside the files has "
                           + "been read — the switch below starts that."
                         : "These placements come from names alone, before any document is read. Nothing "
                           + "moves until you approve it in Organize.")
                        .scaledFont(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // **The legend goes with the line it explains.** A failed Save's heading,
                    // reason and next step are taller than that line, and on the tightest screen
                    // of the ten they pushed the reading switch below the fold at three of the four
                    // named text sizes, by up to 23pt (`structureFitsWithAFailedSaveOnIt`). It
                    // comes back once the failure clears.
                    legendDisclosure
                }
            }

            Divider().opacity(0.4)

            readingToggle

            Spacer(minLength: 0)
        }
    }

    /// What each grey word means, behind a disclosure — see ``legend``.
    private var legendDisclosure: some View {
        SetupMoreOptions(subtitle: "what each gray word means") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Self.legend, id: \.term) { entry in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.term)
                            .scaledFont(.caption.weight(.medium))
                            .frame(width: 132, alignment: .leading)
                        Text(entry.meaning)
                            .scaledFont(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// What the readings mean, in the screen's own words.
    ///
    /// **Behind a disclosure rather than printed under the tree.** The design draws it open, and it
    /// does not fit: the tree box is the tallest thing on this card by a wide margin and six
    /// definitions under it push the reading switch — the control the button below acts on — off
    /// the bottom of a 610pt card. Closed, it costs one line and says what is inside it.
    static let legend: [(term: String, meaning: String)] = [
        ("files go here", "holds files; loose files can be filed into it"),
        ("holds folders only", "nothing is filed into it directly"),
        ("a year · a country · a person",
         "pattern folders, in whatever order your tree uses; files land in the year folder"),
        ("inbox · archive",
         "left alone: nothing is filed into an inbox, and an archive is never reorganized"),
        ("statement, account", "words from the folder’s path and file names, used to match new files"),
        ("the number", "folders inside, or files where files go"),
    ]

    /// **Fixed, so the reading switch below never moves.** The tree is the one thing on this sheet
    /// whose length depends on the user's disk; a box that grew with it would put the switch — and
    /// the button that acts on it — somewhere different on every Mac.
    ///
    /// 208 rather than 268: the card's content budget was 38pt larger than the card actually gives
    /// — it had never been charged for the top bar — and this screen was the one that overflowed
    /// once it was. The box scrolls, so what the number costs is how many rows are in view.
    static let treeHeight: CGFloat = 208

    /// The heading over a failed Save's own reason. The button below it tries again.
    static let saveFailedHeading = "Couldn’t save your folder profile, so nothing was written."

    /// The line after the reason: the two ways on, named as the buttons name them.
    static let saveFailedNextStep = "Try again, or choose Continue Without Saving."

    /// One column per count, so the five of them share a rhythm. Wide enough for the longest label
    /// the screen has — "loose at the top" — measured rather than guessed; a narrower column makes
    /// that one collide with the count beside it.
    static let statColumn: CGFloat = 118

    private var blurb: String {
        if model.structureAwaitsReading {
            return "SyncCloud is still reading the folder names in \(model.walkRootName). "
                + "What it finds appears here when it’s done."
        }
        if model.walkFailureReason != nil {
            return "SyncCloud couldn’t read the folder names in \(model.walkRootName), so there "
                + "is nothing to save. Try another folder, or continue without one."
        }
        return model.structureIsReadOnly
            ? "This Mac already has a folder profile. Click a folder to open or close it."
            : "SyncCloud read this from the folder names in \(model.walkRootName). "
              + "Click a folder to open or close it."
    }

    // MARK: - The five numbers

    private var statsRow: some View {
        // **Even columns, because the labels are not.** Spaced by a constant, the five numbers land
        // at 86, 67, 158 and 84pt apart — the gaps are whatever each label happens to be wide, and
        // "loose at the top" is two words longer than the rest, so the row reads as five unrelated
        // figures rather than as one strip of counts.
        let counts = Self.counts(model)
        return HStack(alignment: .top, spacing: 0) {
            stat(counts.folders, "folder", "folders")
            stat(counts.files, "file", "files")
            stat(counts.loose, "loose at the top", "loose at the top")
            stat(counts.people, "person", "people")
            stat(counts.countries, "country", "countries")
            Spacer(minLength: 0)
        }
    }

    /// The five counts, nil for one there is no reading to give.
    struct Counts: Equatable {
        var folders: Int?
        var files: Int?
        var loose: Int?
        var people: Int
        var countries: Int?
    }

    /// What the stats row says.
    ///
    /// **Dashes for what the reading counts, while it runs or after it failed** — 0 folders and
    /// 0 files, or the last reading's counts after Learn Again, said something no reading had
    /// found. The people are the roster's, whatever the reading does; the countries are reset from
    /// what the reading proposes when it lands, so they wait for it too.
    static func counts(_ model: SetupModel) -> Counts {
        let people = model.rosterNames.count
        guard !model.structureShowsWalkStatus else {
            return Counts(folders: nil, files: nil, loose: nil, people: people, countries: nil)
        }
        let walk = model.walkState.walk
        let profile = model.structureShownProfile
        return Counts(
            // Folders below the root — the walk's own count where there is one, the profile's
            // otherwise.
            folders: walk?.folderCount ?? max((profile?.folders.count ?? 1) - 1, 0),
            files: walk?.fileCount ?? (profile?.folders.values.reduce(0) { $0 + $1.fileCount } ?? 0),
            // The walk's own count, not the routing's: "loose at the top" is a fact about the
            // folder, and it must not change because routing was capped or has not run.
            loose: walk?.looseFileNames.count ?? model.looseRoutes.count,
            people: people,
            countries: model.confirmedCountries.count)
    }

    /// What a count with no reading behind it draws.
    static let unknownCount = "—"

    /// One count and its label — `one` for exactly one, `many` for any other number, and a dash
    /// over the plural for a count there is no reading to give.
    private func stat(_ value: Int?, _ one: String, _ many: String) -> some View {
        let label = value == 1 ? one : many
        return VStack(alignment: .leading, spacing: 0) {
            Text(value?.formatted() ?? Self.unknownCount)
                .scaledFont(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(width: Self.statColumn, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { "\($0.formatted()) \(label)" } ?? "\(label) not known yet")
    }

    // MARK: - The offer

    /// The document-reading offer, on by default.
    ///
    /// **The button below says what it will do**, because a button called *Looks right* once hid
    /// three side effects, one of them three hours long. With the switch on it reads "Save and
    /// Start Reading"; with it off, "Save".
    private var readingToggle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("Read documents", isOn: $model.readDocuments)
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(model.structureShowsWalkStatus
                      ? "Available once SyncCloud has read the folder names"
                      : "Read page one of each document in the background after you save")
                .disabled(!model.structureReadingSwitchIsEnabled)
            Text(readingDetail)
                .scaledFont(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var readingDetail: String {
        guard let walk = model.walkState.walk, walk.documentCount > 0 else {
            return "· page one of each, in the background. Pause or stop any time."
        }
        return "· page one of each, in the background. "
            + "\(DocumentSurveyCost.phrase(documents: walk.documentCount)) "
            + "Pause or stop any time."
    }
}

/// The Why panel beside Structure — it has none, and this is the closing line instead.
///
/// Structure is its own explanation: the tree, the legend and the counts are the argument. What a
/// Why panel would have said is the one line under the button.
enum StructureClosing {
    static let ifWrong = "If this looks wrong: go back and fix a name, a country or the folder. "
        + "Nothing has moved, and nothing is saved until you press Save."
}
