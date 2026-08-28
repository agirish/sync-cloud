import Design
import Testing
@testable import FileExplorer

/// The point of extracting ``LensIntros`` is that every surface naming a lens shows the SAME
/// explanation, and that every lens which can touch files says what it will and won't do. Both are
/// claims about content, so they are testable without rendering anything.
@Suite struct LensIntroTests {

    /// **``LensIntros/all``, not a list maintained here.** This used to be a hand-written array
    /// in this file, which is the shape that cannot catch what it exists to catch: a lens added
    /// to `LensIntros` and not to the array is a lens with no safety contract and a green suite.
    /// The roster now lives beside the intros themselves, and `theRosterHoldsEveryIntro` below is
    /// what keeps *it* honest.
    private var all: [(name: String, intro: LensIntro)] { LensIntros.all }

    @Test func theRosterHoldsEveryIntro() {
        // Naming them: the sweep above is only as good as this set, and "6 entries" would pass on
        // six copies of the same one. Each is checked by identity against the function that
        // produces it, so a roster entry pointing at the wrong intro fails here rather than
        // silently double-covering one lens and skipping another.
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
        #expect(LensIntros.duplicates(targetName: "Family").safety.contains("undoable"))
        #expect(LensIntros.duplicates(targetName: "Family").safety.contains("confirmation"))
        #expect(LensIntros.organize(scanTargetName: "TODO").safety.contains("undoable"))
        #expect(LensIntros.renames(providerName: nil).safety.contains("undoable"))
        #expect(LensIntros.storage(providerName: nil).safety.contains("Read-only"))
        // Restructure stopped being read-only at §5.5: a reviewed plan's Apply moves files. Its
        // contract is now the same family as Organize's — reviewed, recorded, undoable — and the
        // one claim its card must never make again is the old "nothing is renamed or moved".
        #expect(LensIntros.restructure(providerName: nil).safety.contains("review"))
        #expect(LensIntros.restructure(providerName: nil).safety.contains("undoable"))
        #expect(!LensIntros.restructure(providerName: nil).safety.contains("Nothing is created"))
        // Rules never moves a file itself — a rule steers a suggestion, and the suggestion is
        // still confirmed. Both halves, because either alone overstates or understates it.
        // ("previewed" belongs to the message, not the contract: what a preview shows you is
        // part of the pitch, whereas "nothing moves without your confirmation" is the promise.)
        #expect(LensIntros.rules(providerName: nil).safety.contains("only steer"))
        #expect(LensIntros.rules(providerName: nil).safety.contains("confirmation"))
    }

    @Test func theProviderAndTargetReachTheTitle() {
        // The intro is shown from the header too, where there is no surrounding empty state to say
        // which folder is meant — so the naming has to be in the intro itself.
        // Duplicates names the FOCUSED FOLDER — its scan hashes the folder you stand on, and
        // a provider-named title was the same too-wide claim its clean state used to make.
        #expect(LensIntros.duplicates(targetName: "Family").title.contains("Family"))
        #expect(LensIntros.organize(scanTargetName: "TODO").title.contains("TODO"))
        // Renames names the PROVIDER — its detectors read the provider-wide taxonomy, and a
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
