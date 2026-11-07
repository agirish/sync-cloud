import Design
import Foundation

/// The one place each lens's explanation and safety contract is written.
///
/// Both surfaces that show it read from here, the pre-scan `EmptyStateView` and, for Organize,
/// ``FilingSetupCard``, so the prose can't drift between them. That matters most for the safety
/// line, which tells someone whether a lens can move or delete their files.
///
/// Provider and folder names are passed in, so every surface naming the lens says "in iCloud" about
/// the same folder.
enum LensIntros {

    /// Named for the focused folder, not the provider: the duplicate scan hashes the folder you
    /// are standing on (`duplicateScanRoot`), so naming the provider would claim too wide a scope.
    static func duplicates(targetName: String) -> LensIntro {
        LensIntro(
            icon: "wand.and.stars",
            title: "Find duplicates in \(targetName)",
            message: "Scan this folder for folders and files that repeat across its tree — then collapse them into one.",
            safety: "Nothing is removed without your confirmation, and everything is undoable."
        )
    }

    /// Named for the provider: the rename detectors read the provider-wide taxonomy, so
    /// "in <folder>" would promise a narrower answer than the one given.
    static func renames(providerName: String?) -> LensIntro {
        LensIntro(
            icon: "folder.badge.gearshape",
            title: "Check names across \(providerName ?? "this provider")",
            // Three categories in two lines: a third line puts this card's trigger below every
            // other lens's (`everyLensTriggerLandsAtTheSameHeight`).
            //
            // "Files" in the last clause, because a `RenamePlan` is identified by a folder but every
            // step renames a file inside it, as the sample rows show.
            //
            // "Won't store cleanly", not "this provider can't store": an iCloud or folder source has
            // no naming rules of its own and still fills the to-fix section, because
            // `NameNormalizer`'s invisible-hazard layer runs on every provider.
            message: "Find names worth changing — ones that won’t store cleanly, files that ignore their folder’s convention, and files whose numbering has drifted.",
            safety: "Nothing is renamed without your say-so, and every rename is undoable."
        )
    }

    /// `documentsRead` false adds one line: this lens gets better once the documents have been
    /// read, and Organize's overview is where that is offered.
    ///
    /// A sentence, not a second button: starting a three-hour pass from a lens about to scan would
    /// put two long jobs one click apart. The line says where to go and what it buys.
    static func organize(scanTargetName: String, documentsRead: Bool = true) -> LensIntro {
        let extra = documentsRead ? ""
            : " It goes on names and folder shapes for now — reading your documents, offered on "
                + "Organize’s overview, lets it use what a file says too. That reading happens on "
                + "this Mac and is never sent anywhere."
        return LensIntro(
            icon: FilingGlyph.lens,
            title: "File loose files in \(scanTargetName)",
            message: "Suggest where the files sitting loose in this folder belong — reusing the folders you already keep, and proposing new ones only when it’s sure." + extra,
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

    /// Named for the provider, like Renames: the detectors compare families of sibling folders
    /// across the surveyed tree, not within the folder you stand on.
    ///
    /// The lens's cards reach actions that move things (a reviewed plan's Apply, the scaffold, the
    /// removal sheet), so the safety line promises the review gate, not read-onlyness. Safety copy
    /// that denies what the surface does is worse than none.
    static func restructure(providerName: String?) -> LensIntro {
        LensIntro(
            icon: "square.stack.3d.up",
            title: "Compare folder shapes across \(providerName ?? "this provider")",
            message: "Find families of sibling folders that were set up differently at different times — the same kind of folder, organized four ways.",
            // One line: the setup cards share a header budget (two lines of message, one of
            // safety), measured by `everyLensTriggerLandsAtTheSameHeight`. Scoped to a plan's
            // landing because a scaffold is recorded without a chain anchor, so the ledger undo
            // can't see it; promising every landing is undoable would claim a post-quit undo the
            // scaffold lacks.
            safety: "Changes go through a plan you review, and a plan’s landing can be undone."
        )
    }

    /// Named for the provider: a rule steers every scan of the tree, not one folder's. Rules has no
    /// scan of its own (the trigger writes the first rule), so its safety line says what a rule can
    /// do once it exists, which is what someone decides on this screen.
    static func rules(providerName: String?) -> LensIntro {
        LensIntro(
            icon: AutomationsGlyph.lens,
            title: "Automate where loose files go in \(providerName ?? "this provider")",
            message: "Write a plain-words rule — “PDFs that mention ‘invoice’ belong in Documents/Invoices/{year}” — and preview on this Mac which files it would file.",
            safety: "Rules only steer suggestions, and nothing moves without your confirmation."
        )
    }

    /// Every lens's intro, so "does each one state a safety contract?" is asked of the whole set
    /// rather than a list in a test file that a new lens could miss. The arguments are stand-ins;
    /// tests that care about interpolation call the functions directly.
    static var all: [(name: String, intro: LensIntro)] {
        [("Duplicates", duplicates(targetName: "Family")),
         ("Organize", organize(scanTargetName: "TODO")),
         ("Renames", renames(providerName: "iCloud")),
         ("Restructure", restructure(providerName: "iCloud")),
         ("Rules", rules(providerName: "iCloud")),
         ("Storage", storage(providerName: "iCloud"))]
    }
}
