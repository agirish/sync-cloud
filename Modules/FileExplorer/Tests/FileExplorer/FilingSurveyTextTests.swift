import Foundation
import Testing
@testable import FileExplorer
@testable import Sync

/// To File's words about the survey that placed its cards (GK–GN): the menu's label names whose
/// survey it is, and the by-name strip gives the measurement that decided it.
@Suite struct FilingSurveyTextTests {

    static func use(_ kind: FilingSurveyInUse.Kind, matched: Int = 2_499, total: Int = 2_745,
                    own: Int? = nil) -> FilingSurveyInUse {
        FilingSurveyInUse(kind: kind, root: "/g", matched: matched, total: total, chosen: false,
                          ownProfileId: own == nil ? nil : "source-1", ownFolderCount: own)
    }

    @Test func theMenuNamesWhoseSurveyPlacedTheCards() {
        #expect(FilingSurveyText.menuTitle(Self.use(.borrowed), primaryName: "iCloud Drive")
                == "Using iCloud Drive’s Survey")
        #expect(FilingSurveyText.menuTitle(Self.use(.own, own: 4_045), primaryName: "iCloud Drive")
                == "Using Its Own Survey")
        #expect(FilingSurveyText.menuTitle(Self.use(.byName), primaryName: "iCloud Drive") == "No Survey")
        #expect(FilingSurveyText.primaryItem(Self.use(.borrowed), primaryName: "iCloud Drive")
                == "iCloud Drive’s Survey — 91% of folders match")
        #expect(FilingSurveyText.ownItem(Self.use(.own, own: 4_045), sourceName: "Google Drive")
                .hasPrefix("Google Drive’s Own Survey — 4"))
    }

    @Test func theByNameStripSaysWhyAndThatNothingDownloads() {
        let detail = FilingSurveyText.byNameDetail(Self.use(.byName, matched: 28, total: 4_045))
        #expect(detail.hasPrefix("28 of its 4"))
        #expect(detail.contains("by name only"))
        #expect(detail.contains("Nothing downloads"))
        #expect(FilingSurveyText.byNameTitle(sourceName: "Google Drive", primaryName: "iCloud Drive")
                == "Google Drive is laid out differently from iCloud Drive.")
    }

    @Test func theNoteSaysWhatLearnDid() {
        let learned = SourceSurveyNote(root: "/g", learnedFolders: 7, failure: nil)
        #expect(FilingSurveyText.note(learned, sourceName: "Google Drive")
                == "Learned Google Drive’s 7 folders. To File now places its files by that layout.")
        let failed = SourceSurveyNote(root: "/g", learnedFolders: nil, failure: .nothingToLearn("/g/Empty"))
        #expect(FilingSurveyText.note(failed, sourceName: "Google Drive")
                .hasPrefix("Couldn’t learn Google Drive’s folders. “Empty” holds no folders"))
    }
}
