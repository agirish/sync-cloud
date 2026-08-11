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
            message: "Find names that need changing — provider-hostile names that break sync, files that don't follow their folder's convention, and folders that have drifted from their own numbering.",
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
            safety: "Read-only: Storage Lens never moves, deletes, or evicts anything — the “Offload” button just reveals a file in Finder."
        )
    }
}
