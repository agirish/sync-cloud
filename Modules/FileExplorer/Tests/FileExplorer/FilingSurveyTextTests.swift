import Foundation
import Testing
@testable import FileExplorer
@testable import Sync

/// To File's words about the survey that placed its cards: the menu's label names whose survey it
/// is, and the by-name strip gives the measurement that decided it.
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

    /// Read Documents: the menu item, and the strip's progress naming the source.
    @Test func readingASourceNamesItInTheStrip() {
        #expect(FilingSurveyText.readItem(sourceName: "Google Drive") == "Read Google Drive’s Documents…")
        let started = Date(timeIntervalSince1970: 1_780_315_200)
        let reading = DocumentSurveyProgress(completed: 4_360, total: 12_825, phase: .reading,
                                             startedAt: started, readingSeconds: 60)
        #expect(FilingSurveyText.reading(sourceName: "Google Drive", reading)
                == "Reading Google Drive’s documents · 4,360 of 12,825")
        let paused = DocumentSurveyProgress(completed: 4_360, total: 12_825, phase: .paused(.user),
                                            startedAt: started, readingSeconds: 60)
        #expect(FilingSurveyText.reading(sourceName: "Google Drive", paused)
                == "Reading Google Drive’s documents · paused at 4,360 of 12,825")
        let finishing = DocumentSurveyProgress(completed: 12_825, total: 12_825, phase: .finishing,
                                               startedAt: started, readingSeconds: 60)
        #expect(FilingSurveyText.reading(sourceName: "Google Drive", finishing)
                == "Learning from Google Drive’s documents…")
    }
}
