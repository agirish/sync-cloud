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

    private var profile: FolderProfile? { model.structureProfile }

    var body: some View {
        VStack(alignment: .leading, spacing: SetupRhythm.blockSpacing) {
            SetupHeading(title: "Here is how you file", blurb: blurb)

            statsRow

            if model.structureIsReadOnly {
                SetupNote(text: "This is the folder profile this Mac already has. Learn a folder "
                          + "again to replace it — nothing here is written.",
                          systemImage: "info.circle")
            } else {
                Picker("", selection: $lens) {
                    ForEach(Lens.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accentedSegments(hue)
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
                                      : "\(model.looseRoutes.count) files sitting loose here",
                                  routes: lens == .loose && !model.structureIsReadOnly
                                      ? model.looseRoutes : [],
                                  hue: hue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: Self.treeHeight * cardScale)
                } else {
                    SetupNote(text: "Nothing has been learned yet.", systemImage: "folder")
                        .frame(height: Self.treeHeight * cardScale, alignment: .top)
                }

                Text(lens == .folders
                     ? "Grey words are how each folder's name was read. Nothing inside the files has "
                       + "been read — the switch below starts that."
                     : "These placements come from names alone, before any document is read. Nothing "
                       + "moves until you approve it in Organize.")
                    .scaledFont(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                SetupMoreOptions(subtitle: "what each grey word means") {
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

            Divider().opacity(0.4)

            readingToggle

            Spacer(minLength: 0)
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
         "left alone: nothing is filed into an inbox, and an archive is never reorganised"),
        ("statement, account", "words from the folder's path and file names, used to match new files"),
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

    /// One column per count, so the five of them share a rhythm. Wide enough for the longest label
    /// the screen has — "loose at the top" — measured rather than guessed; a narrower column makes
    /// that one collide with the count beside it.
    static let statColumn: CGFloat = 118

    private var blurb: String {
        model.structureIsReadOnly
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
        HStack(alignment: .top, spacing: 0) {
            stat(folderCount, "folders")
            stat(fileCount, "files")
            // The walk's own count, not the routing's: "loose at the top" is a fact about the
            // folder, and it must not change because routing was capped or has not run.
            stat(model.walkState.walk?.looseFileNames.count ?? model.looseRoutes.count,
                 "loose at the top")
            stat(model.rosterNames.count, "people")
            stat(model.confirmedCountries.count, "countries")
            Spacer(minLength: 0)
        }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted())
                .scaledFont(.title3.weight(.semibold))
                .monospacedDigit()
            Text(label)
                .scaledFont(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(width: Self.statColumn, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    /// Folders below the root — the walk's own count where there is one, the profile's otherwise.
    private var folderCount: Int {
        if let walk = model.walkState.walk { return walk.folderCount }
        return max((profile?.folders.count ?? 1) - 1, 0)
    }

    private var fileCount: Int {
        model.walkState.walk?.fileCount
            ?? (profile?.folders.values.reduce(0) { $0 + $1.fileCount } ?? 0)
    }

    // MARK: - The offer

    /// The document-reading offer, on by default.
    ///
    /// **The button below says what it will do**, because a button called *Looks right* once hid
    /// three side effects, one of them three hours long. With the switch on it reads "Save and
    /// start reading"; with it off, "Save".
    private var readingToggle: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("Read documents", isOn: $model.readDocuments)
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(model.structureIsReadOnly)
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
