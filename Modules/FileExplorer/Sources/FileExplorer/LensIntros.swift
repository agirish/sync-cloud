import Design
import Foundation

/// The one place each lens's explanation and safety contract is written.
///
/// Both surfaces that show it read from here — the pre-scan `EmptyStateView` and, for Organize,
/// ``FilingSetupCard``. That is the whole point of extracting them: the two are the same
/// explanation shown at different moments, and prose duplicated across two call sites drifts in
/// one of them. The safety line especially, which is the sentence that tells someone whether a
/// lens can move or delete their files.
///
/// Provider- and folder-specific wording is passed in rather than baked in, so every surface
/// naming the lens says "in iCloud" about the same folder rather than something more generic.
enum LensIntros {

    /// Named for the FOCUSED FOLDER, not the provider: the duplicate scan hashes the folder
    /// you are standing on (`duplicateScanRoot`), and a title promising the provider for a
    /// folder-scoped scan is the same too-wide claim the clean state used to make.
    static func duplicates(targetName: String) -> LensIntro {
        LensIntro(
            icon: "wand.and.stars",
            title: "Find duplicates in \(targetName)",
            message: "Scan this folder for folders and files that repeat across its tree — then collapse them into one.",
            safety: "Nothing is removed without your confirmation, and everything is undoable."
        )
    }

    /// Named for the PROVIDER, deliberately: the rename detectors read the provider-wide
    /// taxonomy, so "in <folder>" here would promise a narrower answer than the one given.
    static func renames(providerName: String?) -> LensIntro {
        LensIntro(
            icon: "folder.badge.gearshape",
            title: "Check names across \(providerName ?? "this provider")",
            // Three categories in two lines. The long form named each one twice over
            // ("provider-hostile names that break sync", "folders that have drifted from their
            // own numbering") and ran to three, which is a full line taller than every other
            // lens's header and the reason their triggers stopped lining up.
            message: "Find names worth changing — ones this provider can't store, files that ignore their folder's convention, and folders whose numbering has drifted.",
            safety: "Nothing is renamed without your say-so, and every rename is undoable."
        )
    }

    static func organize(scanTargetName: String) -> LensIntro {
        LensIntro(
            icon: FilingGlyph.lens,
            title: "File loose files in \(scanTargetName)",
            message: "Suggest where the files sitting loose in this folder belong — reusing the folders you already keep, and proposing new ones only when it's sure.",
            safety: "Nothing moves without your say-so, and every move is undoable."
        )
    }

    static func storage(providerName: String?) -> LensIntro {
        LensIntro(
            icon: "chart.pie.fill",
            title: "See where your space goes in \(providerName ?? "this provider")",
            message: "Analyze this folder to map its biggest areas, list the largest and longest-untouched files, and flag large files worth making online-only.",
            safety: "Read-only: it never moves, deletes, or evicts — “Offload” only reveals in Finder."
        )
    }

    /// Named for the PROVIDER, like Renames: the detectors compare families of sibling folders
    /// across the surveyed tree, not within the folder you happen to stand on.
    ///
    /// Its safety line is the odd one out and says so plainly — **Restructure cannot touch a
    /// file at all.** It reports where the tree disagrees with itself and stops there (see
    /// ``RestructureLens`` for why the fix is a separate surface with its own invariants). A
    /// contract borrowed from the lenses that *do* move things would promise a confirmation step
    /// for an action this lens has no way to take.
    static func restructure(providerName: String?) -> LensIntro {
        LensIntro(
            icon: "square.stack.3d.up",
            title: "Compare folder shapes across \(providerName ?? "this provider")",
            message: "Find families of sibling folders that were set up differently at different times — the same kind of folder, organized four ways.",
            safety: "Read-only: it names the disagreement. Nothing is created, renamed, or moved."
        )
    }

    /// Named for the PROVIDER: a rule is written once and steers every scan of the tree, not one
    /// folder's. Rules is the lens with no scan of its own — the trigger writes the first rule —
    /// so its safety line is about what a rule can do once it exists, which is the thing someone
    /// is actually deciding on this screen.
    static func rules(providerName: String?) -> LensIntro {
        LensIntro(
            icon: AutomationsGlyph.lens,
            title: "Automate where loose files go in \(providerName ?? "this provider")",
            message: "Write a plain-words rule — “PDFs that mention ‘invoice’ belong in Documents/Invoices/{year}” — and preview on this Mac which files it would file.",
            safety: "Rules only steer suggestions, and nothing moves without your confirmation."
        )
    }

    /// Every lens's intro, so "does each one state a safety contract?" can be asked of the whole
    /// set rather than of a list someone remembered to extend.
    ///
    /// A hand-written array in the test file was what this replaces, and it had exactly the blind
    /// spot that shape always has: a lens added here but not there is a lens with no contract and
    /// a green suite. The arguments are stand-ins — the tests that care about interpolation call
    /// the functions directly.
    static var all: [(name: String, intro: LensIntro)] {
        [("Duplicates", duplicates(targetName: "Family")),
         ("Organize", organize(scanTargetName: "TODO")),
         ("Renames", renames(providerName: "iCloud")),
         ("Restructure", restructure(providerName: "iCloud")),
         ("Rules", rules(providerName: "iCloud")),
         ("Storage", storage(providerName: "iCloud"))]
    }
}
