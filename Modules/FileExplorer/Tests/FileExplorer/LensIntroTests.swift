import Design
import Testing
@testable import FileExplorer

/// Every surface naming a lens shows the same ``LensIntros`` explanation, and every lens that can
/// touch files says what it will and won't do. Both are claims about content, so they are testable
/// without rendering anything.
@Suite struct LensIntroTests {

    /// ``LensIntros/all``, not a list kept here: a lens added to `LensIntros` but not to a local
    /// list would have no safety contract and a green suite. `theRosterHoldsEveryIntro` keeps the
    /// roster honest.
    private var all: [(name: String, intro: LensIntro)] { LensIntros.all }

    @Test func theRosterHoldsEveryIntro() {
        // Named one by one, because "6 entries" would pass on six copies of the same intro. Each is
        // checked against the function that produces it, so a roster entry pointing at the wrong
        // intro fails here rather than covering one lens twice and skipping another.
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0.intro) })
        #expect(byName["Duplicates"] == LensIntros.duplicates(targetName: "Family"))
        #expect(byName["Organize"] == LensIntros.organize(scanTargetName: "TODO"))
        #expect(byName["Renames"] == LensIntros.renames(providerName: "iCloud"))
        #expect(byName["Restructure"] == LensIntros.restructure(providerName: "iCloud"))
        #expect(byName["Rules"] == LensIntros.rules(providerName: "iCloud"))
        #expect(byName["Storage"] == LensIntros.storage(providerName: "iCloud"))
        #expect(all.count == 6, "A lens gained an intro without being named here")
    }

    @Test func everyLensStatesASafetyContract() {
        // `EmptyStateView` documents its caption slot as the safety contract. A lens that can't
        // fill it is a lens whose blast radius nobody has written down.
        for (name, intro) in all {
            #expect(!intro.safety.isEmpty, "\(name) has no safety contract")
            #expect(!intro.title.isEmpty, "\(name) has no title")
            #expect(!intro.message.isEmpty, "\(name) has no message")
            #expect(!intro.icon.isEmpty, "\(name) has no icon")
        }
    }

    @Test func theSafetyLineSaysWhatTheLensDoesToFiles() {
        // Each word is the operative promise. Duplicates and Organize are undoable and confirmed;
        // Storage touches nothing at all, which is why its results can be restored and not theirs.
        #expect(LensIntros.duplicates(targetName: "Family").safety.contains("undoable"))
        #expect(LensIntros.duplicates(targetName: "Family").safety.contains("confirmation"))
        #expect(LensIntros.organize(scanTargetName: "TODO").safety.contains("undoable"))
        #expect(LensIntros.renames(providerName: nil).safety.contains("undoable"))
        #expect(LensIntros.storage(providerName: nil).safety.contains("Read-only"))
        // Restructure's Apply moves files, so its contract is Organize's family: reviewed,
        // recorded, undoable, and never "nothing is renamed or moved". The undo claim is scoped to
        // a plan's landing, because a scaffold is recorded without a chain anchor (invisible to
        // `undoableReorganisation`), so "every landing is undoable" would promise an undo it lacks.
        #expect(LensIntros.restructure(providerName: nil).safety.contains("review"))
        #expect(LensIntros.restructure(providerName: nil).safety
            .contains("a plan’s landing can be undone"))
        #expect(!LensIntros.restructure(providerName: nil).safety.contains("Nothing is created"))
        // Rules never moves a file itself: a rule steers a suggestion, which is still confirmed.
        // Both halves, because either alone overstates or understates it. ("previewed" belongs to
        // the message, not the contract.)
        #expect(LensIntros.rules(providerName: nil).safety.contains("only steer"))
        #expect(LensIntros.rules(providerName: nil).safety.contains("confirmation"))
    }

    @Test func theProviderAndTargetReachTheTitle() {
        // The intro is also shown from the header, with no empty state around it to say which
        // folder is meant, so the naming has to be in the intro itself.
        // Duplicates names the focused folder, because its scan hashes the folder you stand on.
        #expect(LensIntros.duplicates(targetName: "Family").title.contains("Family"))
        #expect(LensIntros.organize(scanTargetName: "TODO").title.contains("TODO"))
        // Renames names the provider: its detectors read the provider-wide taxonomy, and a
        // folder-named title would promise a narrower answer than the one given.
        #expect(LensIntros.renames(providerName: "Dropbox").title.contains("Dropbox"))
        #expect(LensIntros.storage(providerName: "Dropbox").title.contains("Dropbox"))
        // Restructure and Rules name the provider for the same reason Renames does: a family of
        // sibling folders and a rule are both tree-wide, not folder-scoped.
        #expect(LensIntros.restructure(providerName: "Dropbox").title.contains("Dropbox"))
        #expect(LensIntros.rules(providerName: "Dropbox").title.contains("Dropbox"))
    }

    @Test func anUnnamedProviderStillReadsAsASentence() {
        #expect(LensIntros.renames(providerName: nil).title.contains("this provider"))
        #expect(LensIntros.storage(providerName: nil).title.contains("this provider"))
        #expect(LensIntros.restructure(providerName: nil).title.contains("this provider"))
        #expect(LensIntros.rules(providerName: nil).title.contains("this provider"))
    }
}
