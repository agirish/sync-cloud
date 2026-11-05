import Design
import SwiftUI
import Sync

/// What SyncCloud read, shown back before anything is written.
///
/// A walk that reports only counts can't be checked. Here the reading is on screen while going
/// Back still costs nothing, so a wrong name, country or folder is caught before the profile
/// exists, not after Organize has acted on it.
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
    /// The tree box is sized in points but its contents scale, so it scales too, or large text
    /// shows only a few rows. It follows the card, not the type: on a window too small for the
    /// card's full growth it would claim room the card never got and push the switch below out of
    /// sight. `SetupSheetFitTests` measures it.
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

            // The tree, the line explaining its grey words and the legend are one block at the
            // tighter spacing: three parts of one thing, on the screen with no height to spare.
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
                    // The reading is running or failed: the same line People and Countries draw,
                    // in the box the tree will fill.
                    SetupWalkStatus(model: model, foundLabel: "Read from")
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(height: Self.treeHeight * cardScale, alignment: .top)
                } else {
                    SetupNote(text: "Nothing has been learned yet.", systemImage: "folder")
                        .frame(height: Self.treeHeight * cardScale, alignment: .top)
                }

                // A failed Save shows here, in place of the grey-words line, because the press
                // stays on this screen, next to the button that tries again. Worded as a failed
                // write: the folder was read, and the tree is still above.
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

                    // The legend goes with the line it explains. A failed Save's text is taller
                    // than that line, and with the legend too it would push the reading switch
                    // below the fold (`structureFitsWithAFailedSaveOnIt`). It returns once the
                    // failure clears.
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

    /// What the readings mean, in the screen's own words. Behind a disclosure, because six
    /// definitions under the tree push the reading switch, which the button below acts on, off
    /// the bottom of the card. Closed, it costs one line.
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

    /// Fixed, so the reading switch below never moves: the tree's length depends on the user's
    /// disk, and a box that grew with it would put the switch somewhere different on every Mac.
    /// The box scrolls, so the height only sets how many rows are in view; 208 is what fits the
    /// card.
    static let treeHeight: CGFloat = 208

    /// The heading over a failed Save's own reason. The button below it tries again.
    static let saveFailedHeading = "Couldn’t save your folder profile, so nothing was written."

    /// The line after the reason: the two ways on, named as the buttons name them.
    static let saveFailedNextStep = "Try again, or choose Continue Without Saving."

    /// One column per count, so the five share a rhythm. Measured to fit the longest label, "loose
    /// at the top"; narrower, it collides with the count beside it.
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
        // Even columns, because the labels are not. Spaced by a constant, the gaps follow each
        // label's width and the row reads as five unrelated figures, not one strip of counts.
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

    /// What the stats row says. While a reading runs or after it failed, its counts are dashes:
    /// zeros, or the last reading's counts, would claim something no reading found. People come
    /// from the roster regardless; countries are reset from the reading's proposals, so they wait
    /// for it too.
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

    /// The document-reading offer, on by default. The button below names what it will do, so a
    /// long reading never hides behind a vague label: "Save and Start Reading" with the switch on,
    /// "Save" with it off.
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

/// Structure's closing line, in place of a Why panel: the tree, legend and counts explain
/// themselves, and this one line under the button says the rest.
enum StructureClosing {
    static let ifWrong = "If this looks wrong: go back and fix a name, a country or the folder. "
        + "Nothing has moved, and nothing is saved until you press Save."
}
