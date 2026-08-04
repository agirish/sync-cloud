import Design
import Foundation

/// The one place each lens's explanation and safety contract is written.
///
/// Both surfaces that show it read from here — the pre-scan `EmptyStateView` and the header's ⓘ
/// (``LensIntroButton``). That is the whole point of extracting them: the two are the same
/// explanation shown at different moments, and prose duplicated across two call sites drifts in
/// one of them. The safety line especially, which is the sentence that tells someone whether a
/// lens can move or delete their files.
///
/// Provider- and folder-specific wording is passed in rather than baked in, so the empty state
/// keeps saying "in iCloud" while the popover — which can be opened from anywhere — says the same
/// thing about the same lens.
enum LensIntros {

    static func duplicates(providerName: String?) -> LensIntro {
        LensIntro(
            icon: "wand.and.stars",
            title: "Find duplicates in \(providerName ?? "this provider")",
            message: "Scan this provider for folders and files that repeat across the tree — then collapse them into one.",
            safety: "Nothing is removed without your confirmation, and everything is undoable."
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
