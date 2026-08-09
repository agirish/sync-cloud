import Design
import Testing
@testable import FileExplorer

/// The point of extracting ``LensIntros`` is that every surface naming a lens shows the SAME
/// explanation, and that every lens which can touch files says what it will and won't do. Both are
/// claims about content, so they are testable without rendering anything.
@Suite struct LensIntroTests {

    private var all: [(name: String, intro: LensIntro)] {
        [("Duplicates", LensIntros.duplicates(providerName: "iCloud")),
         ("Organize", LensIntros.organize(scanTargetName: "TODO")),
         ("Storage", LensIntros.storage(providerName: "iCloud"))]
    }

    @Test func everyLensStatesASafetyContract() {
        // `EmptyStateView` documents its caption slot as the safety contract. A lens that cannot
        // fill it is a lens whose blast radius nobody has written down.
        for (name, intro) in all {
            #expect(!intro.safety.isEmpty, "\(name) has no safety contract")
            #expect(!intro.title.isEmpty, "\(name) has no title")
            #expect(!intro.message.isEmpty, "\(name) has no message")
            #expect(!intro.icon.isEmpty, "\(name) has no icon")
        }
    }

    @Test func theSafetyLineSaysWhatTheLensDoesToFiles() {
        // Not a spelling test — each of these words is the operative promise. Duplicates and
        // Organize are undoable and confirmed; Storage is the one that touches nothing at all,
        // and that difference is the reason its results can be restored when theirs cannot.
        #expect(LensIntros.duplicates(providerName: nil).safety.contains("undoable"))
        #expect(LensIntros.duplicates(providerName: nil).safety.contains("confirmation"))
        #expect(LensIntros.organize(scanTargetName: "TODO").safety.contains("undoable"))
        #expect(LensIntros.storage(providerName: nil).safety.contains("Read-only"))
    }

    @Test func theProviderAndTargetReachTheTitle() {
        // The intro is shown from the header too, where there is no surrounding empty state to say
        // which folder is meant — so the naming has to be in the intro itself.
        #expect(LensIntros.duplicates(providerName: "Dropbox").title.contains("Dropbox"))
        #expect(LensIntros.organize(scanTargetName: "TODO").title.contains("TODO"))
        #expect(LensIntros.storage(providerName: "Dropbox").title.contains("Dropbox"))
    }

    @Test func anUnnamedProviderStillReadsAsASentence() {
        #expect(LensIntros.duplicates(providerName: nil).title.contains("this provider"))
        #expect(LensIntros.storage(providerName: nil).title.contains("this provider"))
    }
}
