import Foundation
import Testing
@testable import Sync

/// The words the Structure screen puts on each folder.
///
/// Every reading is a restatement of an entry the builder produced, so these are written against a
/// profile built from a fixture tree rather than a hand-written profile: a reading that passes on a
/// profile the builder would never produce is a sentence about nothing.
@Suite struct FolderReadingTests {

    private static func profile(folders: [String], files: [String] = [],
                               countries: Set<String> = [],
                               registry: PersonRegistry? = nil) -> FolderProfile {
        FolderSurveyBuilder.build(tree: FixtureTree.of(folders: folders, files: files),
                                  root: "~/Documents", profileId: "test",
                                  registry: registry, jurisdictionValues: countries)
    }

    private static func read(_ path: String, of profile: FolderProfile) -> String {
        FolderReading.reading(for: path, in: profile,
                              children: FolderReading.childrenByParent(profile),
                              shapes: FolderReading.shapeFindings(in: profile))
    }

    // MARK: - The sibling map

    /// The root's children are the tree view's top level, and the detector's own map drops them.
    @Test func theRootsChildrenAreKept() {
        let map = FolderReading.childrenByParent(Self.profile(folders: ["Finance/US", "Family"]))
        #expect(map[FolderSurveyBuilder.rootEntryPath] == ["Family", "Finance"])
        #expect(map["Finance"] == ["Finance/US"])
        #expect(StructureDivergence.families(in: Self.profile(folders: ["Finance/US", "Family"]))[
            FolderSurveyBuilder.rootEntryPath] == nil,
            "if the detector's map ever keeps the root, this type has one job fewer")
    }

    // MARK: - One rule at a time

    /// An inbox is read as an inbox before it is read as anything else — it is the one role that
    /// changes what the app will *do* with the folder.
    @Test func anInboxSaysNothingWillBeFiledThere() {
        let profile = Self.profile(folders: ["Finance/TODO", "Finance/Receipts"])
        #expect(Self.read("Finance/TODO", of: profile) == "inbox: nothing will be filed here")
    }

    @Test func anArchiveSaysItIsLeftAlone() {
        let profile = Self.profile(folders: ["Finance/Archive"])
        #expect(Self.read("Finance/Archive", of: profile) == "archive: left as it is")
    }

    @Test func anEmptyFolderSaysSo() {
        let profile = Self.profile(folders: ["Finance/Receipts"])
        #expect(Self.read("Finance/Receipts", of: profile) == "empty")
    }

    /// A year bucket carries its anchors, because "a year" alone does not tell two of them apart.
    @Test func aYearBucketNamesTheYearAndItsAnchors() {
        let profile = Self.profile(folders: ["Finance/Income Tax/2024"],
                                   files: ["Finance/Income Tax/2024/return.pdf"])
        #expect(Self.read("Finance/Income Tax/2024", of: profile) == "a year · income, tax")
    }

    /// Only the folder whose own name is the country reads as one; its children inherit the axis
    /// and would otherwise all claim to be countries.
    @Test func onlyTheCountryFolderItselfReadsAsACountry() {
        let profile = Self.profile(folders: ["Finance/US/Banking", "Legal/US", "School/US"],
                                   files: ["Finance/US/Banking/a.pdf"],
                                   countries: ["US"])
        #expect(Self.read("Finance/US", of: profile) == "a country")
        #expect(Self.read("Finance/US/Banking", of: profile) != "a country")
    }

    @Test func aPersonBucketReadsAsAPerson() {
        let registry = PersonRegistry(people: [Person(id: "p1", displayName: "Mother",
                                                      relationship: "mother")])
        let profile = Self.profile(folders: ["Family/Mother"],
                                   files: ["Family/Mother/passport.pdf"], registry: registry)
        #expect(Self.read("Family/Mother", of: profile) == "a person")
    }

    /// A destination is where filing lands, so the reading says that and then what it is about.
    @Test func aDestinationSaysFilesGoThere() {
        let profile = Self.profile(folders: ["Finance/Banking"],
                                   files: ["Finance/Banking/statement.pdf"])
        #expect(Self.read("Finance/Banking", of: profile) == "files go here · finance, banking",
                "the anchors are the profile's, parent words and all")
    }

    /// A folder whose children are all people is described by naming them — the one case where the
    /// members are more use than the shape.
    @Test func aFolderOfPeopleNamesThem() {
        let registry = PersonRegistry(people: [
            Person(id: "p1", displayName: "Mother", relationship: "mother"),
            Person(id: "p2", displayName: "Father", relationship: "father"),
        ])
        let profile = Self.profile(folders: ["Family/Mother", "Family/Father"],
                                   files: ["Family/Mother/a.pdf", "Family/Father/b.pdf"],
                                   registry: registry)
        #expect(Self.read("Family", of: profile) == "a folder per person: Father, Mother")
    }

    /// A container with nothing to say about its levels still says what it is.
    @Test func aContainerWithNoDiscernibleShapeSaysItHoldsFolders() {
        let profile = Self.profile(folders: ["Home/Utilities"],
                                   files: ["Home/Utilities/bill.pdf"])
        #expect(Self.read("Home", of: profile) == "holds folders only")
    }

    // MARK: - The shape sentence

    /// Two levels, each with a majority: the sentence the screen's legend is written against.
    @Test func nestedLevelsAreReadInOrder() {
        let profile = Self.profile(folders: [
            "Finance/US/2023", "Finance/US/2024", "Finance/IN/2023", "Finance/IN/2024",
        ], files: ["Finance/US/2023/a.pdf"], countries: ["US", "IN"])
        #expect(Self.read("Finance", of: profile) == "a country first, then the year")
    }

    /// One level is a list, not a habit — nothing is claimed about a tree one folder deep.
    @Test func oneLevelIsNotAShape() {
        let profile = Self.profile(folders: ["Finance/US", "Finance/IN"], countries: ["US", "IN"])
        #expect(FolderReading.shapeSentence(under: "Finance", in: profile,
                                            children: FolderReading.childrenByParent(profile)) == nil)
    }

    /// A level of one folder is an example, not a majority.
    @Test func aLevelOfOneFolderStopsTheSentence() {
        let profile = Self.profile(folders: ["Finance/US/2023/Q1", "Finance/US/2024",
                                             "Finance/IN/2023", "Finance/IN/2024"],
                                   countries: ["US", "IN"])
        let sentence = FolderReading.shapeSentence(under: "Finance", in: profile,
                                                   children: FolderReading.childrenByParent(profile))
        #expect(sentence == "a country first, then the year",
                "the one Q1 at the third level is an example, not a habit")
    }

    /// Folders organised by something the profile does not record are still described, in the one
    /// word that is honest about it.
    @Test func alevelWithNoAxisIsTheKindOfThing() {
        let profile = Self.profile(folders: [
            "Home/Utilities/Water", "Home/Utilities/Power",
            "Home/Insurance/Car", "Home/Insurance/House",
        ], files: ["Home/Utilities/Water/a.pdf"])
        #expect(Self.read("Home", of: profile)
                == "the kind of thing first, then the kind of thing")
    }

    /// A family whose siblings disagree is quoted from the finding rather than described, so the
    /// tree row and the Restructure lens say the same number.
    @Test func aDivergentFamilyQuotesItsFinding() throws {
        let profile = Self.profile(folders: [
            "Statements/Chase/Cards", "Statements/Chase/Loans",
            "Statements/Amex/Cards", "Statements/Amex/Loans",
            "Statements/Citi/Notices", "Statements/Citi/Summaries",
            "Statements/HSBC/Notices", "Statements/HSBC/Summaries",
        ], files: ["Statements/Chase/2023/a.pdf"])
        let finding = try #require(FolderReading.shapeFindings(in: profile)["Statements"])
        #expect(Self.read("Statements", of: profile)
                == "\(finding.memberCount) folders, \(finding.schemes.count) internal shapes")
    }

    // MARK: - The reference shapes, together

    /// The five rows the Structure screen is drawn with, read off one profile.
    @Test func theScreensOwnExampleReadsAsDrawn() {
        let registry = PersonRegistry(people: [
            Person(id: "p1", displayName: "Mother", relationship: "mother"),
            Person(id: "p2", displayName: "Father", relationship: "father"),
        ])
        let profile = Self.profile(folders: [
            "Finance/US/Income Tax/2023", "Finance/US/Income Tax/2024",
            "Finance/IN/Income Tax/2023", "Finance/IN/Income Tax/2024",
            "Finance/TODO", "Home/Utilities", "Family/Mother", "Family/Father",
        ], files: ["Finance/US/Income Tax/2024/return.pdf", "Home/Utilities/bill.pdf",
                   "Family/Mother/passport.pdf", "Family/Father/licence.pdf"],
        countries: ["US", "IN"], registry: registry)

        #expect(Self.read("Finance", of: profile)
                == "a country first, then the kind of thing, then the year")
        #expect(Self.read("Finance/US", of: profile) == "a country")
        #expect(Self.read("Finance/US/Income Tax", of: profile) == "holds folders only",
                "one level of years is a list, and the sentence is about how levels nest")
        #expect(Self.read("Finance/TODO", of: profile) == "inbox: nothing will be filed here")
        #expect(Self.read("Family", of: profile) == "a folder per person: Father, Mother")
        #expect(Self.read("Home", of: profile) == "holds folders only")
    }
}
