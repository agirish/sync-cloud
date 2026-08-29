import Foundation
import Sync

/// The rename backlog, reorganized category-first (v4.0 polish P10): sections by what the pass
/// would *do* — naming, reshuffling, padding — because the three operations ask different things
/// of the user, and 132 visually identical folder rows asked them to discover that by opening
/// every chevron. Within a section, folders follow path order and are drawn as cards.
///
/// **The plan stays the atomic unit.** A folder's steps are chosen against each other, so half a
/// plan is not a smaller plan — a section therefore holds whole folders, classified by the most
/// consequential kind of step their plan contains, and every button applies whole plans. A
/// mixed folder's pads ride along with its namings, exactly as they do when its own row button
/// is clicked; what the section changes is where you *find* the folder, not what applying it does.
enum RenameCategories {

    /// Most consequential first — the same rule `RenameBacklogTally` orders its prose by:
    /// naming gives a raw name a slot (a judgment about intent), a reshuffle touches files that
    /// were already correct, a pad only respells. This is also the section order on screen.
    enum Category: Int, CaseIterable, Equatable {
        case name, reshuffle, pad

        /// The step kind that puts a plan in this category.
        var kind: RenameStep.Kind {
            switch self {
            case .name: return .placed
            case .reshuffle: return .renumbered
            case .pad: return .tidied
            }
        }

        /// The pill's word, matching the tally's vocabulary exactly — one measurement, one name.
        var label: String {
            switch self {
            case .name: return "to name"
            case .reshuffle: return "to reshuffle"
            case .pad: return "to pad"
            }
        }

        /// The section's one-line definition — what this kind of change asks of you.
        var definition: String {
            switch self {
            case .name: return "Files that don't follow their folder's convention — a judgment about intent."
            case .reshuffle: return "Renumbers files that already have numbers — shifts their neighbours."
            case .pad: return "Leading zeros so one-digit ordinals sort before “10.” — mechanical."
            }
        }
    }

    struct Section: Equatable {
        let category: Category
        /// The section's folders, in path order.
        let plans: [RenamePlan]
        var fileCount: Int { plans.reduce(0) { $0 + $1.steps.count } }
        /// Steps of the section's own kind — the pill's number. A mixed folder contributes its
        /// pads to `fileCount` (the button applies them) but not to this claim.
        var kindCount: Int {
            let kind = category.kind
            return plans.reduce(0) { $0 + $1.steps.filter { $0.kind == kind }.count }
        }
    }

    /// A plan's category: the most consequential kind of step it contains, nil for a plan of
    /// nothing but skips (those are the "left alone" footnote, not a section row).
    static func category(of plan: RenamePlan) -> Category? {
        for category in Category.allCases where plan.steps.contains(where: { $0.kind == category.kind }) {
            return category
        }
        return nil
    }

    /// The screen: sections in consequence order, present only when they report (the
    /// sections-vanish-at-zero rule), folders in path order within each. Every plan with steps
    /// lands in exactly one section; skip-only plans are `leftAlone`.
    ///
    /// **Path order, not a parent grouping.** These used to nest one level deeper: folders were
    /// bucketed under their immediate parent, and each bucket carried a header and a chevron of
    /// its own. Sorting on the whole relative path puts the same folders in the same order — a
    /// parent is a prefix of its children's paths — without a second collapsible layer between
    /// the section and the thing being read, and each card states its own path anyway.
    static func sections(_ plans: [RenamePlan]) -> [Section] {
        var buckets: [Category: [RenamePlan]] = [:]
        for plan in plans {
            guard let category = category(of: plan) else { continue }
            buckets[category, default: []].append(plan)
        }
        return Category.allCases.compactMap { category in
            guard let members = buckets[category], !members.isEmpty else { return nil }
            return Section(category: category,
                           plans: members.sorted { $0.relativePath < $1.relativePath })
        }
    }

    /// Plans the pass looked at and declined to touch entirely.
    static func leftAlone(_ plans: [RenamePlan]) -> [RenamePlan] {
        plans.filter { $0.steps.isEmpty && !$0.skips.isEmpty }
    }

    /// The folder name a card leads with; the path beneath it carries the rest.
    static func leaf(of relativePath: String) -> String {
        (relativePath as NSString).lastPathComponent
    }
}
